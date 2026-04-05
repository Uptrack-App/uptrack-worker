defmodule UptrackWorker.Monitoring.MonitorProcess do
  @moduledoc """
  Regional check worker GenServer.

  Performs HTTP checks and broadcasts results via pg to all regions.
  Does NOT write to database or trigger alerts — that's the home node's job.

  ## Pipeline

      check → broadcast result to pg group → collect other regions → track consensus

  ## Differences from main app MonitorProcess
  - No DB writes (no record_result)
  - No alert triggering (no maybe_trigger_alert)
  - No Events broadcasting (no Phoenix.PubSub)
  - Uses plain map for monitor (not Ecto schema)
  """

  use GenServer

  alias UptrackWorker.Monitoring.{GunConnection, Consensus, MonitorRegistry}

  require Logger

  @check_client Application.compile_env(:uptrack_worker, :check_client, UptrackWorker.Monitoring.CheckClient.Gun)
  @region Application.compile_env(:uptrack_worker, :node_region, :us)

  @consensus_timeout_ms 10_000

  defstruct [
    :monitor_id,
    :monitor,
    :interval_ms,
    :conn,
    :consecutive_failures,
    status: :active,
    checking: false,
    consensus: %Consensus{}
  ]

  # --- Client API ---

  def start_link(monitor) do
    GenServer.start_link(__MODULE__, monitor, name: MonitorRegistry.via(monitor.id))
  end

  def update_config(monitor_id, monitor) do
    GenServer.cast(MonitorRegistry.via(monitor_id), {:update_config, monitor})
  end

  def stop(monitor_id) do
    GenServer.cast(MonitorRegistry.via(monitor_id), :stop)
  end

  # --- Init ---

  @impl true
  def init(monitor) do
    conn = case @check_client.open_connection(monitor) do
      {:ok, c} -> c
      {:error, reason} ->
        Logger.error("MonitorProcess #{monitor.id}: connection failed: #{inspect(reason)}")
        nil
    end

    # Join pg group for cross-region result broadcasting
    :pg.join(:monitor_checks, monitor.id, self())

    expected = expected_regions(monitor.id)

    state = %__MODULE__{
      monitor_id: monitor.id,
      monitor: monitor,
      interval_ms: (monitor.interval || 30) * 1000,
      consecutive_failures: 0,
      conn: conn,
      consensus: %Consensus{expected_regions: expected}
    }

    jitter = :rand.uniform(max(state.interval_ms, 1000))
    schedule_check(jitter)

    Logger.debug("MonitorProcess started: #{monitor.name} (#{monitor.id}) region=#{@region}")
    {:ok, state}
  end

  # --- Check scheduling ---

  @impl true
  def handle_info(:check, %{status: :paused} = state) do
    schedule_check(state.interval_ms)
    {:noreply, state}
  end

  def handle_info(:check, %{checking: true} = state) do
    schedule_check(state.interval_ms)
    {:noreply, state}
  end

  def handle_info(:check, %{status: :active, checking: false} = state) do
    parent = self()
    monitor = state.monitor
    conn = state.conn
    check_client = @check_client

    Task.Supervisor.start_child(UptrackWorker.TaskSupervisor, fn ->
      result = try do
        check_client.check(monitor, conn)
      rescue
        e -> %{monitor_id: monitor.id, status: "down", response_time: 0,
               checked_at: DateTime.utc_now() |> DateTime.truncate(:second),
               error_message: "Check error: #{Exception.message(e)}"}
      catch
        kind, reason -> %{monitor_id: monitor.id, status: "down", response_time: 0,
                          checked_at: DateTime.utc_now() |> DateTime.truncate(:second),
                          error_message: "Check #{kind}: #{inspect(reason)}"}
      end
      send(parent, {:check_result, result})
    end)

    schedule_check(state.interval_ms)
    {:noreply, %{state | checking: true}}
  end

  # --- Check result + consensus ---

  def handle_info({:check_result, result}, state) do
    consensus = Consensus.add_result(state.consensus, @region, result)
    broadcast_to_group(state.monitor_id, @region, result)
    consensus = maybe_start_timer(consensus)

    state = %{state | consensus: consensus, checking: false}
    {:noreply, try_consensus(state)}
  end

  # Receive result from another region via pg
  def handle_info({:region_result, region, result}, state) do
    consensus = Consensus.add_result(state.consensus, region, result)
    state = %{state | consensus: consensus}
    {:noreply, try_consensus(state)}
  end

  def handle_info(:consensus_timeout, state) do
    consensus = Consensus.timeout(state.consensus)
    state = %{state | consensus: consensus}
    {:noreply, try_consensus(state)}
  end

  # --- Gun lifecycle ---

  def handle_info({:gun_up, _pid, _protocol}, state) do
    {:noreply, %{state | conn: GunConnection.connected(state.conn)}}
  end

  def handle_info({:gun_down, _pid, _protocol, _reason, _}, state) do
    {:noreply, %{state | conn: GunConnection.disconnected(state.conn)}}
  end

  def handle_info({:gun_error, _pid, _reason}, state), do: {:noreply, state}
  def handle_info({:gun_error, _pid, _stream, _reason}, state), do: {:noreply, state}

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{conn: %GunConnection{ref: conn_ref}} = state)
      when ref == conn_ref do
    Logger.warning("MonitorProcess #{state.monitor_id}: Gun died: #{inspect(reason)}, reconnecting")
    conn = case @check_client.open_connection(state.monitor) do
      {:ok, c} -> c
      {:error, _} -> nil
    end
    {:noreply, %{state | conn: conn}}
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state), do: {:noreply, state}
  def handle_info({:gun_data, _pid, _stream, _fin, _data}, state), do: {:noreply, state}
  def handle_info(_msg, state), do: {:noreply, state}

  # --- Config updates ---

  @impl true
  def handle_cast({:update_config, monitor}, state) do
    {:noreply, %{state |
      monitor: monitor,
      interval_ms: (monitor.interval || 30) * 1000
    }}
  end

  def handle_cast(:stop, state) do
    {:stop, :normal, state}
  end

  @impl true
  def terminate(_reason, state) do
    if state.conn, do: @check_client.close_connection(state.conn)
    cancel_consensus_timer(state.consensus)
    :ok
  end

  # --- Consensus (tracking only — no DB/alerts) ---

  defp try_consensus(state) do
    if Consensus.enough_results?(state.consensus) do
      result = Consensus.compute(state.consensus)
      cancel_consensus_timer(state.consensus)

      consecutive_failures = case result do
        "down" -> state.consecutive_failures + 1
        _ -> 0
      end

      %{state |
        consecutive_failures: consecutive_failures,
        consensus: Consensus.reset(state.consensus)
      }
    else
      state
    end
  end

  # --- Helpers ---

  defp broadcast_to_group(monitor_id, region, result) do
    :pg.get_members(:monitor_checks, monitor_id)
    |> Kernel.--([self()])
    |> Enum.each(&send(&1, {:region_result, region, result}))
  end

  defp maybe_start_timer(%Consensus{timer: nil} = c) do
    timer = Process.send_after(self(), :consensus_timeout, @consensus_timeout_ms)
    %{c | timer: timer}
  end

  defp maybe_start_timer(c), do: c

  defp cancel_consensus_timer(%Consensus{timer: nil}), do: :ok
  defp cancel_consensus_timer(%Consensus{timer: ref}) do
    Process.cancel_timer(ref)
    :ok
  end

  defp schedule_check(delay_ms) do
    Process.send_after(self(), :check, delay_ms)
  end

  defp expected_regions(monitor_id) do
    case :pg.get_members(:monitor_checks, monitor_id) do
      members when is_list(members) -> max(length(members), 1)
      _ -> 1
    end
  end
end
