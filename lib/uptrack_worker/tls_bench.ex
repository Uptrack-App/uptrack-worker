defmodule UptrackWorker.TlsBench do
  @moduledoc """
  Benchmark TLS handshake CPU cost on the existing OTP `:ssl` stack.

  Measures three modes against the same target:
    1. **Fresh handshake** — each connect does a full TLS handshake
       (`reuse_sessions: false`). Worst case: every probe check against
       a unique host with no pool.
    2. **Resumed handshake** — TLS 1.2 session resumption / 1.3 PSK.
       What you'd see with default OTP `:ssl` client cache after first
       connect to a host.
    3. **Pooled request** — one open conn, N HTTP requests reusing it.
       What you'd see with a healthy Finch pool to a hot host.

  The ratio fresh : resumed : pooled tells you how much TLS handshake
  CPU you'd save by tightening connection pooling — relevant ceiling
  for scaling past 1M monitors/node.

  Default target: example.com:443 (stable public test endpoint).

  WARNING: makes real network calls. Don't run against arbitrary
  third-party endpoints at scale — use a controlled host you own for
  high-N runs.
  """

  @default_host "example.com"
  @default_port 443
  @default_path "/"

  def bench_all(n \\ 100, host \\ @default_host, port \\ @default_port) do
    %{
      fresh: bench_fresh(n, host, port),
      resumed: bench_resumed(n, host, port),
      pooled: bench_pooled(n, host, port)
    }
  end

  @doc "Mode 1: every connect does a full handshake (no session reuse)."
  def bench_fresh(n, host, port) do
    do_bench(n, fn ->
      single_handshake(host, port, reuse_sessions: false)
    end)
    |> annotate(:fresh)
  end

  @doc """
  Mode 2: relies on OTP `:ssl` client session cache. First handshake is
  full; subsequent re-connects to the same host resume.
  """
  def bench_resumed(n, host, port) do
    # Prime the session cache with one full handshake first.
    _ = single_handshake(host, port, reuse_sessions: true)

    do_bench(n, fn ->
      single_handshake(host, port, reuse_sessions: true)
    end)
    |> annotate(:resumed)
  end

  @doc "Mode 3: open conn once, send N HTTP/1.1 requests over it."
  def bench_pooled(n, host, port) do
    host_cl = String.to_charlist(host)

    case :ssl.connect(host_cl, port, ssl_opts(reuse_sessions: true), 10_000) do
      {:ok, sock} ->
        try do
          do_bench(n, fn ->
            t0 = System.monotonic_time(:microsecond)

            req =
              "GET #{@default_path} HTTP/1.1\r\n" <>
                "Host: #{host}\r\n" <>
                "Connection: keep-alive\r\n" <>
                "User-Agent: tls-bench/1.0\r\n\r\n"

            :ok = :ssl.send(sock, req)
            # Read until end-of-headers + first body chunk; good enough for
            # a per-request latency measurement that includes round-trip.
            _ = read_response(sock, 8_192)

            {:ok, System.monotonic_time(:microsecond) - t0}
          end)
          |> annotate(:pooled)
        after
          :ssl.close(sock)
        end

      {:error, reason} ->
        %{error: reason, mode: :pooled}
    end
  end

  defp single_handshake(host, port, opts) do
    host_cl = String.to_charlist(host)
    t0 = System.monotonic_time(:microsecond)

    case :ssl.connect(host_cl, port, ssl_opts(opts), 10_000) do
      {:ok, sock} ->
        elapsed = System.monotonic_time(:microsecond) - t0
        :ssl.close(sock)
        {:ok, elapsed}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp ssl_opts(opts) do
    [
      verify: :verify_none,
      active: false,
      versions: [:"tlsv1.3", :"tlsv1.2"],
      server_name_indication: String.to_charlist(@default_host)
    ] ++ opts
  end

  defp read_response(sock, max_bytes) do
    case :ssl.recv(sock, 0, 2_000) do
      {:ok, data} when byte_size(data) >= max_bytes ->
        {:ok, data}

      {:ok, _data} ->
        # Got something — good enough for benchmarking; don't drain the
        # entire response or we measure body-read latency instead of
        # request-response latency.
        :ok

      {:error, _} = err ->
        err
    end
  end

  defp do_bench(n, fun) do
    # Warm up — first run includes any one-time JIT / atom creation.
    _ = fun.()

    {runtime_before, _} = :erlang.statistics(:runtime)
    wall_before = System.monotonic_time(:millisecond)

    results = Enum.map(1..n, fn _ -> fun.() end)

    {runtime_after, _} = :erlang.statistics(:runtime)
    wall_after = System.monotonic_time(:millisecond)

    {oks, errs} =
      Enum.split_with(results, fn
        {:ok, _} -> true
        _ -> false
      end)

    times = Enum.map(oks, fn {:ok, t} -> t end) |> Enum.sort()
    n_ok = length(times)
    cpu_us_total = (runtime_after - runtime_before) * 1000
    cpu_us_per = if n_ok > 0, do: round(cpu_us_total / n_ok), else: 0

    %{
      n: n,
      successes: n_ok,
      errors: length(errs),
      first_error: List.first(errs),
      total_wall_ms: wall_after - wall_before,
      total_cpu_ms: runtime_after - runtime_before,
      cpu_us_per_op: cpu_us_per,
      max_ops_per_sec_per_core: if(cpu_us_per > 0, do: round(1_000_000 / cpu_us_per), else: nil),
      wall_us_per_op_p50: pct(times, 0.50),
      wall_us_per_op_p90: pct(times, 0.90),
      wall_us_per_op_p99: pct(times, 0.99)
    }
  end

  defp pct([], _), do: 0

  defp pct(sorted, p) do
    n = length(sorted)
    Enum.at(sorted, max(0, min(n - 1, round((n - 1) * p))))
  end

  defp annotate(result, mode), do: Map.put(result, :mode, mode)
end
