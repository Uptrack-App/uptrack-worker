defmodule UptrackWorker.EtsBench do
  @moduledoc """
  Memory benchmark for the ETS + worker pool architecture (vs the existing
  GenServer-per-monitor pattern measured by `UptrackWorker.Tools.bench/1`).

  Models the proposed architecture:
    - :monitor_state ETS table (one row per monitor — config + scheduling fields)
    - Fixed worker pool of N processes (idle in this bench — we measure
      memory shape, not throughput)
    - :monitor_consensus would also exist but is empty for idle monitors,
      so we skip it here

  Goal: confirm per-monitor memory cost lands in the 200–500 B range
  predicted by the architecture sketch, which would beat the hibernated
  GenServer floor (~3 KB) by ~10×.
  """

  @worker_pool_size 128

  @doc """
  Populate ETS with `n` synthetic monitor rows + spawn an idle worker pool.
  Measure total VM memory + per-monitor cost. Cleanup before returning.

  Two modes:
    - `:shared_settings` (default) — every row references the same settings
      binary (realistic when monitors share configs; exploits refc binary
      sharing across ETS rows)
    - `:unique_settings` — every row gets its own settings map (worst case
      when every monitor has bespoke config)
  """
  def bench(n, mode \\ :shared_settings) do
    cleanup()

    before_mem = :erlang.memory(:total)
    before_procs = :erlang.system_info(:process_count)

    table =
      :ets.new(:bench_monitor_state, [
        :set,
        :public,
        :named_table,
        read_concurrency: true,
        write_concurrency: true
      ])

    shared_settings = :erlang.term_to_binary(%{"foo" => "bar", "headers" => %{}})
    now = System.monotonic_time(:millisecond)

    Enum.each(1..n, fn i ->
      monitor_id = "bench-#{i}"
      next_check_at = now + :rand.uniform(60_000)

      settings =
        case mode do
          :shared_settings -> shared_settings
          :unique_settings -> :erlang.term_to_binary(%{"monitor_idx" => i, "headers" => %{}})
        end

      :ets.insert(
        table,
        {
          monitor_id,
          "http://127.0.0.1:1/path/#{i}",
          30_000,
          5_000,
          :active,
          next_check_at,
          0,
          :up,
          settings
        }
      )
    end)

    workers =
      Enum.map(1..@worker_pool_size, fn _ ->
        spawn_link(fn -> worker_loop() end)
      end)

    # Let allocations settle.
    :timer.sleep(2_000)

    after_mem = :erlang.memory()
    after_procs = :erlang.system_info(:process_count)
    info = :ets.info(:bench_monitor_state)
    ets_words = Keyword.get(info, :memory, 0)
    ets_bytes = ets_words * :erlang.system_info(:wordsize)

    Enum.each(workers, fn pid ->
      Process.unlink(pid)
      Process.exit(pid, :kill)
    end)

    :ets.delete(:bench_monitor_state)

    %{
      target: n,
      mode: mode,
      ets_rows: Keyword.get(info, :size, 0),
      beam_procs_delta: after_procs - before_procs,
      total_mb: mb(after_mem[:total]),
      delta_mb: mb(after_mem[:total] - before_mem),
      processes_mb: mb(after_mem[:processes]),
      binary_mb: mb(after_mem[:binary]),
      ets_mb: mb(ets_bytes),
      ets_bytes_per_row: round(ets_bytes / n),
      total_delta_bytes_per_monitor: round((after_mem[:total] - before_mem) / n),
      worker_pool_size: @worker_pool_size
    }
  end

  defp worker_loop do
    receive do
      _msg -> worker_loop()
    after
      60_000 -> worker_loop()
    end
  end

  defp cleanup do
    if :ets.info(:bench_monitor_state) != :undefined do
      :ets.delete(:bench_monitor_state)
    end

    :ok
  end

  defp mb(nil), do: 0.0
  defp mb(bytes), do: Float.round(bytes / 1_048_576, 2)
end
