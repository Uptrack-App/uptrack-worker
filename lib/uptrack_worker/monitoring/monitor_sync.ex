defmodule UptrackWorker.Monitoring.MonitorSync do
  @moduledoc """
  Syncs monitor list from the main app via :erpc on cluster join.

  On startup, waits for cluster connection, then fetches all active monitors
  from the main app and starts MonitorProcess for each one.

  Also listens for monitor config changes via pg group `:monitor_config`.
  """

  use GenServer

  alias UptrackWorker.Monitoring.{MonitorSupervisor, MonitorRegistry}

  require Logger

  @retry_interval_ms 5_000
  @main_app_module Uptrack.Monitoring

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @impl true
  def init(:ok) do
    # Join config update group to receive create/update/delete from main app
    :pg.join(:monitor_config, :workers, self())

    # Try to sync immediately, retry if no cluster peers yet
    send(self(), :sync)
    {:ok, %{synced: false}}
  end

  @impl true
  def handle_info(:sync, %{synced: true} = state) do
    {:noreply, state}
  end

  def handle_info(:sync, state) do
    case find_main_node() do
      {:ok, main_node} ->
        Logger.info("MonitorSync: connected to main app at #{main_node}, fetching monitors...")
        sync_monitors(main_node)
        {:noreply, %{state | synced: true}}

      :no_peers ->
        Logger.debug("MonitorSync: no cluster peers yet, retrying in #{@retry_interval_ms}ms")
        Process.send_after(self(), :sync, @retry_interval_ms)
        {:noreply, state}
    end
  end

  # Main app pushes monitor creation
  def handle_info({:monitor_created, monitor}, state) do
    Logger.info("MonitorSync: received new monitor #{monitor.id}")
    monitor_map = to_monitor_map(monitor)
    MonitorSupervisor.start_monitor(monitor_map)
    {:noreply, state}
  end

  # Main app pushes monitor update
  def handle_info({:monitor_updated, monitor}, state) do
    Logger.info("MonitorSync: updated monitor #{monitor.id}")
    monitor_map = to_monitor_map(monitor)

    case MonitorRegistry.lookup(monitor.id) do
      {:ok, _pid} ->
        UptrackWorker.Monitoring.MonitorProcess.update_config(monitor.id, monitor_map)
      :error ->
        MonitorSupervisor.start_monitor(monitor_map)
    end

    {:noreply, state}
  end

  # Main app pushes monitor deletion/pause
  def handle_info({:monitor_deleted, monitor_id}, state) do
    Logger.info("MonitorSync: removing monitor #{monitor_id}")
    MonitorSupervisor.stop_monitor(monitor_id)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # --- Private ---

  defp find_main_node do
    case Node.list() do
      [] -> :no_peers
      nodes ->
        # Find main app node (runs Uptrack.Application, not UptrackWorker)
        main = Enum.find(nodes, fn n ->
          try do
            :erpc.call(n, :erlang, :function_exported, [@main_app_module, :list_all_active_monitors, 0], 5_000)
          catch
            _, _ -> false
          end
        end)

        if main, do: {:ok, main}, else: :no_peers
    end
  end

  defp sync_monitors(main_node) do
    monitors = :erpc.call(main_node, @main_app_module, :list_all_active_monitors, [], 30_000)

    Logger.info("MonitorSync: starting #{length(monitors)} monitors")

    Enum.each(monitors, fn monitor ->
      monitor_map = to_monitor_map(monitor)
      MonitorSupervisor.start_monitor(monitor_map)
    end)
  rescue
    e ->
      Logger.error("MonitorSync: failed to sync: #{inspect(e)}")
      Process.send_after(self(), :sync, @retry_interval_ms)
  end

  # Convert Ecto struct to plain map (worker doesn't have Ecto schemas)
  defp to_monitor_map(%{__struct__: _} = monitor) do
    %{
      id: monitor.id,
      name: monitor.name,
      url: monitor.url,
      interval: monitor.interval,
      timeout: monitor.timeout || 30,
      status: monitor.status,
      settings: monitor.settings || %{},
      confirmation_threshold: monitor.confirmation_threshold || 3,
      organization_id: monitor.organization_id
    }
  end

  defp to_monitor_map(monitor) when is_map(monitor), do: monitor
end
