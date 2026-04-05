defmodule UptrackWorker.Bench do
  @moduledoc """
  Benchmark Gun vs Mint: memory per connection and requests/sec.
  Called via :erpc from the main app.
  """

  @target_url "https://api.uptrack.app/api/health"
  @timeout 10_000

  @doc "Run full benchmark. Returns results map."
  def run(count \\ 1000) do
    IO.puts("=== Gun vs Mint Benchmark (#{count} connections) ===\n")

    # Force GC before each test
    :erlang.garbage_collect()
    Process.sleep(1000)

    gun_result = bench_gun(count)
    IO.puts("Gun done. Cleaning up...")
    cleanup_gun(gun_result.pids)
    :erlang.garbage_collect()
    Process.sleep(2000)

    mint_result = bench_mint(count)
    IO.puts("Mint done. Cleaning up...")
    cleanup_mint(mint_result.conns)
    :erlang.garbage_collect()
    Process.sleep(2000)

    # Throughput test — sequential requests on a single connection
    gun_rps = bench_gun_throughput(100)
    mint_rps = bench_mint_throughput(100)

    IO.puts("\n=== RESULTS ===")
    IO.puts("#{String.pad_leading(Integer.to_string(count), 6)} connections:")
    IO.puts("  Gun:  #{gun_result.total_mb}MB total | #{gun_result.per_conn_kb}KB/conn | #{gun_result.procs} BEAM procs")
    IO.puts("  Mint: #{mint_result.total_mb}MB total | #{mint_result.per_conn_kb}KB/conn | #{mint_result.procs} BEAM procs")
    IO.puts("  Savings: #{Float.round(gun_result.total_mb - mint_result.total_mb, 1)}MB (#{Float.round((1 - mint_result.total_mb / gun_result.total_mb) * 100, 1)}%)")
    IO.puts("")
    IO.puts("Throughput (100 sequential GETs on 1 conn):")
    IO.puts("  Gun:  #{gun_rps.total_ms}ms total | #{gun_rps.avg_ms}ms avg")
    IO.puts("  Mint: #{mint_rps.total_ms}ms total | #{mint_rps.avg_ms}ms avg")

    %{gun: gun_result, mint: mint_result, gun_rps: gun_rps, mint_rps: mint_rps}
  end

  # --- Gun benchmark ---

  defp bench_gun(count) do
    before_mem = :erlang.memory(:total)
    before_procs = :erlang.system_info(:process_count)

    uri = URI.parse(@target_url)
    host = String.to_charlist(uri.host)
    port = uri.port || 443

    pids = for _ <- 1..count do
      {:ok, pid} = :gun.open(host, port, %{
        connect_timeout: @timeout,
        protocols: [:http],
        transport: :tls,
        tls_opts: [verify: :verify_none]
      })
      pid
    end

    # Wait for connections to establish
    for pid <- pids do
      case :gun.await_up(pid, @timeout) do
        {:ok, _} -> :ok
        _ -> :ok
      end
    end

    Process.sleep(1000)

    after_mem = :erlang.memory(:total)
    after_procs = :erlang.system_info(:process_count)
    delta = after_mem - before_mem

    %{
      total_mb: Float.round(delta / 1_048_576, 1),
      per_conn_kb: Float.round(delta / count / 1024, 1),
      procs: after_procs - before_procs,
      pids: pids
    }
  end

  defp cleanup_gun(pids) do
    Enum.each(pids, &:gun.close/1)
  end

  # --- Mint benchmark ---

  defp bench_mint(count) do
    before_mem = :erlang.memory(:total)
    before_procs = :erlang.system_info(:process_count)

    uri = URI.parse(@target_url)

    conns = for _ <- 1..count do
      case Mint.HTTP.connect(:https, uri.host, uri.port || 443,
             transport_opts: [verify: :verify_none]) do
        {:ok, conn} -> conn
        {:error, _} -> nil
      end
    end
    |> Enum.reject(&is_nil/1)

    Process.sleep(1000)

    after_mem = :erlang.memory(:total)
    after_procs = :erlang.system_info(:process_count)
    actual = length(conns)
    delta = after_mem - before_mem

    %{
      total_mb: Float.round(delta / 1_048_576, 1),
      per_conn_kb: Float.round(delta / max(actual, 1) / 1024, 1),
      procs: after_procs - before_procs,
      conns: conns,
      connected: actual
    }
  end

  defp cleanup_mint(conns) do
    Enum.each(conns, fn conn ->
      try do
        Mint.HTTP.close(conn)
      catch
        _, _ -> :ok
      end
    end)
  end

  # --- Throughput: Gun ---

  defp bench_gun_throughput(n) do
    uri = URI.parse(@target_url)
    host = String.to_charlist(uri.host)
    {:ok, pid} = :gun.open(host, uri.port || 443, %{
      connect_timeout: @timeout, protocols: [:http],
      transport: :tls, tls_opts: [verify: :verify_none]
    })
    {:ok, _} = :gun.await_up(pid, @timeout)
    path = uri.path || "/"

    start = System.monotonic_time(:millisecond)
    for _ <- 1..n do
      ref = :gun.get(pid, path, [{"host", uri.host}])
      case :gun.await(pid, ref, @timeout) do
        {:response, :fin, _, _} -> :ok
        {:response, :nofin, _, _} -> :gun.await_body(pid, ref, @timeout); :ok
        _ -> :ok
      end
    end
    total_ms = System.monotonic_time(:millisecond) - start
    :gun.close(pid)

    %{total_ms: total_ms, avg_ms: Float.round(total_ms / n, 1)}
  end

  # --- Throughput: Mint ---

  defp bench_mint_throughput(n) do
    uri = URI.parse(@target_url)
    {:ok, conn} = Mint.HTTP.connect(:https, uri.host, uri.port || 443,
      transport_opts: [verify: :verify_none])
    path = uri.path || "/"

    start = System.monotonic_time(:millisecond)
    conn = Enum.reduce(1..n, conn, fn _, conn ->
      {:ok, conn, ref} = Mint.HTTP.request(conn, "GET", path, [{"host", uri.host}], nil)
      drain_mint_response(conn, ref)
    end)
    total_ms = System.monotonic_time(:millisecond) - start
    Mint.HTTP.close(conn)

    %{total_ms: total_ms, avg_ms: Float.round(total_ms / n, 1)}
  end

  defp drain_mint_response(conn, ref) do
    receive do
      msg ->
        case Mint.HTTP.stream(conn, msg) do
          {:ok, conn, responses} ->
            if Enum.any?(responses, fn r -> match?({:done, ^ref}, r) end) do
              conn
            else
              drain_mint_response(conn, ref)
            end
          {:error, conn, _, _} -> conn
          :unknown -> drain_mint_response(conn, ref)
        end
    after
      @timeout -> conn
    end
  end
end
