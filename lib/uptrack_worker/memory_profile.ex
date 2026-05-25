defmodule UptrackWorker.MemoryProfile do
  @moduledoc """
  Memory profiler for diagnosing the 150k-monitor memory bump.

  Each hypothesis below maps to one or more sections of the snapshot output.
  Run from a remote console on the node under load:

      :erpc.call(:"uptrack_worker@nbg1", UptrackWorker.MemoryProfile, :snapshot, [])

  Or pin to one node and stream into a file for diff over time:

      File.write!("/tmp/profile-\#{DateTime.utc_now() |> DateTime.to_iso8601()}.txt",
        inspect(UptrackWorker.MemoryProfile.snapshot(), pretty: true, limit: :infinity))

  Hypotheses being tested:
    (a) per-process Mint/Gun conns not shared across MonitorProcesses
    (b) Finch pool growing unbounded with diverse hosts
    (c) receive-buffer growth on long-lived idle connections
    (d) HTTP/2 frame buffering accumulating on multiplexed conns
    (e) GenServer state bloat from accumulated check history
  """

  @top_n 20

  def snapshot do
    %{
      timestamp_utc: DateTime.utc_now(),
      node: node(),
      vm: vm_summary(),
      memory_categories: memory_categories(),
      top_processes_by_memory: top_processes(:memory, @top_n),
      top_processes_by_message_queue: top_processes(:message_queue_len, @top_n),
      monitor_processes: monitor_process_stats(),
      connection_processes: connection_process_stats(),
      ets_tables: ets_summary(@top_n),
      ports: port_summary()
    }
  end

  # ── VM-level summary ─────────────────────────────────────────────────────

  defp vm_summary do
    %{
      process_count: :erlang.system_info(:process_count),
      process_limit: :erlang.system_info(:process_limit),
      port_count: :erlang.system_info(:port_count),
      port_limit: :erlang.system_info(:port_limit),
      atom_count: :erlang.system_info(:atom_count),
      schedulers_online: :erlang.system_info(:schedulers_online),
      uptime_sec: :erlang.statistics(:wall_clock) |> elem(0) |> div(1000)
    }
  end

  defp memory_categories do
    mem = :erlang.memory()

    %{
      total_mb: mb(mem[:total]),
      processes_mb: mb(mem[:processes]),
      processes_used_mb: mb(mem[:processes_used]),
      system_mb: mb(mem[:system]),
      atom_mb: mb(mem[:atom]),
      binary_mb: mb(mem[:binary]),
      code_mb: mb(mem[:code]),
      ets_mb: mb(mem[:ets])
    }
  end

  # ── Top processes ────────────────────────────────────────────────────────

  defp top_processes(key, n) do
    Process.list()
    |> Enum.map(fn pid ->
      case Process.info(pid, [:registered_name, :initial_call, :current_function, key, :status]) do
        nil ->
          nil

        info ->
          %{
            pid: inspect(pid),
            registered_name: info[:registered_name],
            initial_call: format_mfa(info[:initial_call]),
            current_function: format_mfa(info[:current_function]),
            status: info[:status],
            value: info[key]
          }
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(& &1.value, :desc)
    |> Enum.take(n)
  end

  defp format_mfa({m, f, a}), do: "#{inspect(m)}.#{f}/#{a}"
  defp format_mfa(other), do: inspect(other)

  # ── MonitorProcess GenServer stats ───────────────────────────────────────
  #
  # Hypothesis (e): GenServer state bloat. We expect each MonitorProcess to
  # hold roughly the same memory; outliers indicate per-monitor state growth
  # (history queues, accumulated bins, etc.).

  defp monitor_process_stats do
    registry = UptrackWorker.Monitoring.MonitorRegistry

    pids =
      case :erlang.whereis(registry) do
        :undefined ->
          []

        _ ->
          Registry.select(registry, [{{:_, :"$1", :_}, [], [:"$1"]}])
      end

    sizes =
      pids
      |> Enum.map(fn pid ->
        case Process.info(pid, [:memory, :message_queue_len, :heap_size, :stack_size, :total_heap_size, :dictionary]) do
          nil -> nil
          info -> info[:memory]
        end
      end)
      |> Enum.reject(&is_nil/1)

    if sizes == [] do
      %{count: 0}
    else
      sorted = Enum.sort(sizes)
      n = length(sorted)

      %{
        count: n,
        total_mb: mb(Enum.sum(sorted)),
        per_process_bytes: %{
          min: List.first(sorted),
          p50: percentile(sorted, 0.50),
          p90: percentile(sorted, 0.90),
          p99: percentile(sorted, 0.99),
          max: List.last(sorted),
          mean: round(Enum.sum(sorted) / n)
        },
        # Outliers worth manual inspection: top 5 monitor processes by memory.
        top_5_pids: top_monitor_pids(pids, 5)
      }
    end
  end

  defp top_monitor_pids(pids, n) do
    pids
    |> Enum.map(fn pid ->
      info = Process.info(pid, [:memory, :message_queue_len, :registered_name, :dictionary])
      case info do
        nil ->
          nil

        _ ->
          %{
            pid: inspect(pid),
            memory_kb: Float.round((info[:memory] || 0) / 1024, 1),
            message_queue_len: info[:message_queue_len],
            registered_name: info[:registered_name]
          }
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(& &1.memory_kb, :desc)
    |> Enum.take(n)
  end

  # ── Connection / HTTP client processes ───────────────────────────────────
  #
  # Hypotheses (a), (b), (c), (d): if Mint/Gun conns are held in dedicated
  # processes, their count and memory tell us whether pooling is working.
  # We classify processes by their initial_call module — Gun, Finch, Mint
  # show up under distinct supervisors.

  defp connection_process_stats do
    classified =
      Process.list()
      |> Enum.map(fn pid ->
        info = Process.info(pid, [:initial_call, :memory, :message_queue_len])
        case info do
          nil ->
            nil

          _ ->
            kind = classify_connection_process(info[:initial_call])
            if kind == :other, do: nil, else: {kind, info[:memory] || 0}
        end
      end)
      |> Enum.reject(&is_nil/1)

    classified
    |> Enum.group_by(fn {kind, _} -> kind end, fn {_, mem} -> mem end)
    |> Enum.map(fn {kind, mems} ->
      sorted = Enum.sort(mems)
      n = length(sorted)

      {kind,
       %{
         count: n,
         total_mb: mb(Enum.sum(sorted)),
         per_process_bytes: %{
           p50: percentile(sorted, 0.50),
           p99: percentile(sorted, 0.99),
           max: List.last(sorted),
           mean: round(Enum.sum(sorted) / n)
         }
       }}
    end)
    |> Map.new()
  end

  defp classify_connection_process({:gun, _, _}), do: :gun
  defp classify_connection_process({:gun_conns_sup, _, _}), do: :gun
  defp classify_connection_process({Finch, _, _}), do: :finch
  defp classify_connection_process({Finch.HTTP1.Pool, _, _}), do: :finch_pool
  defp classify_connection_process({Finch.HTTP1.PoolMetrics, _, _}), do: :finch_pool
  defp classify_connection_process({Finch.HTTP2.Pool, _, _}), do: :finch_pool
  defp classify_connection_process({Mint.HTTP, _, _}), do: :mint
  defp classify_connection_process({:proc_lib, :init_p, _}), do: :other
  defp classify_connection_process(_), do: :other

  # ── ETS tables ───────────────────────────────────────────────────────────

  defp ets_summary(n) do
    :ets.all()
    |> Enum.map(fn tab ->
      info = :ets.info(tab)
      words = Keyword.get(info, :memory, 0)
      bytes = words * :erlang.system_info(:wordsize)

      %{
        name: Keyword.get(info, :name),
        size: Keyword.get(info, :size, 0),
        memory_mb: mb(bytes),
        owner: inspect(Keyword.get(info, :owner))
      }
    end)
    |> Enum.sort_by(& &1.memory_mb, :desc)
    |> Enum.take(n)
  end

  # ── Ports (TCP sockets show up here) ─────────────────────────────────────

  defp port_summary do
    ports = :erlang.ports()

    by_kind =
      ports
      |> Enum.map(fn port ->
        info = :erlang.port_info(port)
        if is_list(info), do: Keyword.get(info, :name, ~c"unknown"), else: ~c"dead"
      end)
      |> Enum.frequencies()
      |> Map.new(fn {name, count} -> {to_string(name), count} end)

    %{total: length(ports), by_kind: by_kind}
  end

  # ── helpers ──────────────────────────────────────────────────────────────

  defp mb(nil), do: 0.0
  defp mb(bytes), do: Float.round(bytes / 1_048_576, 2)

  defp percentile([], _), do: 0
  defp percentile(sorted, p) when p >= 0 and p <= 1 do
    n = length(sorted)
    idx = max(0, min(n - 1, round((n - 1) * p)))
    Enum.at(sorted, idx)
  end
end
