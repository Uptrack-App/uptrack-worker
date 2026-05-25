defmodule UptrackWorker.ThroughputBench do
  @moduledoc """
  Sustained throughput benchmark — answers "how many HTTP checks/sec
  can this machine actually do under steady-state load."

  Spawns a local TCP server that answers HTTP/1.1 with a tiny 200 OK,
  then runs N worker processes that do back-to-back HTTP requests
  against it for `duration_ms`. Reports actual checks/sec, per-check
  CPU, and aggregate scheduler utilization.

  Differs from `UptrackWorker.TlsBench` (single-shot per-op CPU) — this
  measures sustained rate under contention, which is what the
  per-monitor capacity question actually needs.

  Plain HTTP only — TLS overhead is constant per check and was already
  measured in `TlsBench`. To extrapolate to TLS workload, add ~5.7 ms
  CPU per fresh handshake or ~0.24 ms per pooled request.
  """

  @port 5999

  @response_close "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nOK"
  @response_keep_alive "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nOK"
  @response_keep_alive_size byte_size(@response_keep_alive)

  def bench(opts \\ []) do
    workers = Keyword.get(opts, :workers, 100)
    duration_ms = Keyword.get(opts, :duration_ms, 15_000)
    cadence_ms = Keyword.get(opts, :cadence_ms, 0)
    mode = Keyword.get(opts, :mode, :fresh)

    # ── Start local target ─────────────────────────────────────────────
    {:ok, listener} =
      :gen_tcp.listen(@port, [
        :binary,
        packet: :raw,
        active: false,
        reuseaddr: true,
        backlog: 2048
      ])

    Process.flag(:trap_exit, true)
    # Spawn 16 concurrent accepters so the local server doesn't bottleneck
    # at high worker counts. We measure CLIENT-side throughput; server must
    # not be the limit.
    accepters =
      for _ <- 1..16 do
        spawn(fn -> accept_loop(listener) end)
      end

    # ── Enable scheduler accounting ────────────────────────────────────
    :erlang.system_flag(:scheduler_wall_time, true)

    scheds_before = :erlang.statistics(:scheduler_wall_time_all)
    runtime_before = :erlang.statistics(:runtime) |> elem(0)
    wall_before = System.monotonic_time(:millisecond)

    # ── Counters ───────────────────────────────────────────────────────
    counter = :counters.new(2, [:atomics])

    # ── Spawn workers ──────────────────────────────────────────────────
    deadline = wall_before + duration_ms

    pids =
      Enum.map(1..workers, fn _ ->
        spawn(fn -> worker_loop(deadline, cadence_ms, counter, mode) end)
      end)

    # Wait for the deadline plus a settling window
    Process.sleep(duration_ms + 500)

    # ── Stop everything ────────────────────────────────────────────────
    Enum.each(pids, fn pid ->
      if Process.alive?(pid), do: Process.exit(pid, :kill)
    end)

    Enum.each(accepters, fn pid ->
      if Process.alive?(pid), do: Process.exit(pid, :kill)
    end)

    :gen_tcp.close(listener)

    # Drain
    Process.sleep(100)

    # ── Measure ────────────────────────────────────────────────────────
    wall_after = System.monotonic_time(:millisecond)
    runtime_after = :erlang.statistics(:runtime) |> elem(0)
    scheds_after = :erlang.statistics(:scheduler_wall_time_all)

    successes = :counters.get(counter, 1)
    errors = :counters.get(counter, 2)
    elapsed_sec = (wall_after - wall_before) / 1000

    %{
      workers: workers,
      mode: mode,
      cadence_ms: cadence_ms,
      duration_ms: round(elapsed_sec * 1000),
      successes: successes,
      errors: errors,
      actual_checks_per_sec: round(successes / elapsed_sec),
      total_cpu_ms: runtime_after - runtime_before,
      per_check_cpu_us:
        if(successes > 0, do: round((runtime_after - runtime_before) * 1000 / successes), else: nil),
      sched_util_pct: sched_util(scheds_before, scheds_after),
      max_theoretical_cps_at_30s_cadence:
        if(successes > 0, do: round(successes / elapsed_sec * 30), else: nil)
    }
  end

  # ── Worker loop ───────────────────────────────────────────────────────

  # :fresh — open + send + recv + close per check (matches Mint
  # "fresh-conn-per-check" path; bound by ephemeral ports at high N).
  defp worker_loop(deadline, cadence_ms, counter, :fresh) do
    now = System.monotonic_time(:millisecond)

    if now < deadline do
      case do_check_fresh() do
        :ok -> :counters.add(counter, 1, 1)
        _err -> :counters.add(counter, 2, 1)
      end

      if cadence_ms > 0, do: Process.sleep(cadence_ms)

      worker_loop(deadline, cadence_ms, counter, :fresh)
    end
  end

  # :keep_alive — open conn ONCE per worker, send many requests through
  # it (matches Finch pool reuse behaviour; bypasses ephemeral port
  # exhaustion entirely).
  defp worker_loop(deadline, cadence_ms, counter, :keep_alive) do
    case :gen_tcp.connect(~c"127.0.0.1", @port,
           [:binary, active: false, packet: :raw, nodelay: true],
           2000
         ) do
      {:ok, sock} ->
        keep_alive_loop(sock, deadline, cadence_ms, counter)
        :gen_tcp.close(sock)

      _err ->
        :counters.add(counter, 2, 1)
    end
  end

  defp keep_alive_loop(sock, deadline, cadence_ms, counter) do
    now = System.monotonic_time(:millisecond)

    if now < deadline do
      case do_check_keep_alive(sock) do
        :ok ->
          :counters.add(counter, 1, 1)
          if cadence_ms > 0, do: Process.sleep(cadence_ms)
          keep_alive_loop(sock, deadline, cadence_ms, counter)

        _err ->
          :counters.add(counter, 2, 1)
      end
    end
  end

  defp do_check_fresh do
    case :gen_tcp.connect(~c"127.0.0.1", @port, [:binary, active: false, packet: :raw], 2000) do
      {:ok, sock} ->
        result =
          with :ok <- :gen_tcp.send(sock, request_close()),
               {:ok, _data} <- :gen_tcp.recv(sock, 0, 2000) do
            :ok
          else
            err -> err
          end

        :gen_tcp.close(sock)
        result

      err ->
        err
    end
  end

  # Read one HTTP/1.1 keep-alive response: status + headers + 2-byte body.
  # Server sends a fixed-shape response (`@response_keep_alive` below) so
  # we just have to consume exactly that many bytes per request.
  defp do_check_keep_alive(sock) do
    with :ok <- :gen_tcp.send(sock, request_keep_alive()),
         {:ok, _data} <- :gen_tcp.recv(sock, @response_keep_alive_size, 2000) do
      :ok
    else
      err -> err
    end
  end

  defp request_close do
    "GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"
  end

  defp request_keep_alive do
    "GET / HTTP/1.1\r\nHost: localhost\r\n\r\n"
  end

  # ── Local target server ───────────────────────────────────────────────

  defp accept_loop(listener) do
    case :gen_tcp.accept(listener, 500) do
      {:ok, client} ->
        spawn(fn -> handle_client(client) end)
        accept_loop(listener)

      {:error, :timeout} ->
        accept_loop(listener)

      {:error, :closed} ->
        :ok

      {:error, _other} ->
        accept_loop(listener)
    end
  end

  # Server loop handles both fresh and keep-alive clients. Stays open as
  # long as the client keeps sending requests; closes on Connection:
  # close, EOF, or 30s of idle silence.
  defp handle_client(sock) do
    case :gen_tcp.recv(sock, 0, 30_000) do
      {:ok, data} ->
        if String.contains?(data, "Connection: close") do
          :gen_tcp.send(sock, @response_close)
          :gen_tcp.close(sock)
        else
          :gen_tcp.send(sock, @response_keep_alive)
          handle_client(sock)
        end

      _err ->
        :gen_tcp.close(sock)
    end
  end

  # ── Scheduler utilization ─────────────────────────────────────────────

  defp sched_util(before_list, after_list) do
    before_map = Map.new(before_list, fn {id, a, t} -> {id, {a, t}} end)

    online = :erlang.system_info(:schedulers_online)

    pcts =
      after_list
      |> Enum.take(online)
      |> Enum.map(fn {id, a_active, a_total} ->
        {b_active, b_total} = Map.get(before_map, id, {0, 0})
        total_delta = a_total - b_total
        if total_delta > 0, do: round((a_active - b_active) * 100 / total_delta), else: 0
      end)

    if pcts == [], do: 0, else: round(Enum.sum(pcts) / length(pcts))
  end
end
