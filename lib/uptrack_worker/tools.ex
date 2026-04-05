defmodule UptrackWorker.Tools do
  @moduledoc "Public tool helpers callable via :erpc from main app."

  @timeout 15_000

  @doc "One-time HTTP check. Returns {region, result}."
  def check_website(url) do
    region = Application.get_env(:uptrack_worker, :node_region, "unknown")
    start_time = System.monotonic_time(:millisecond)

    try do
      uri = URI.parse(url)
      host = String.to_charlist(uri.host || "localhost")
      port = uri.port || if(uri.scheme == "https", do: 443, else: 80)
      tls? = uri.scheme == "https"

      gun_opts = if tls? do
        %{connect_timeout: @timeout, protocols: [:http], transport: :tls,
          tls_opts: [verify: :verify_none]}
      else
        %{connect_timeout: @timeout, protocols: [:http]}
      end

      case :gun.open(host, port, gun_opts) do
        {:ok, pid} ->
          ref = Process.monitor(pid)
          case :gun.await_up(pid, @timeout) do
            {:ok, _} ->
              path = (uri.path || "/") <> if(uri.query, do: "?#{uri.query}", else: "")
              stream = :gun.get(pid, path, [{"host", uri.host}, {"user-agent", "Uptrack Checker/1.0"}])

              result = case :gun.await(pid, stream, @timeout) do
                {:response, :fin, status, _headers} ->
                  response_time = System.monotonic_time(:millisecond) - start_time
                  %{status: if(status < 400, do: "up", else: "down"), status_code: status, response_time: response_time}

                {:response, :nofin, status, _headers} ->
                  :gun.await_body(pid, stream, @timeout)
                  response_time = System.monotonic_time(:millisecond) - start_time
                  %{status: if(status < 400, do: "up", else: "down"), status_code: status, response_time: response_time}

                {:error, reason} ->
                  response_time = System.monotonic_time(:millisecond) - start_time
                  %{status: "down", response_time: response_time, error: inspect(reason)}
              end

              :gun.close(pid)
              Process.demonitor(ref, [:flush])
              {region, result}

            {:error, reason} ->
              :gun.close(pid)
              Process.demonitor(ref, [:flush])
              response_time = System.monotonic_time(:millisecond) - start_time
              {region, %{status: "down", response_time: response_time, error: "Connection failed: #{inspect(reason)}"}}
          end

        {:error, reason} ->
          response_time = System.monotonic_time(:millisecond) - start_time
          {region, %{status: "down", response_time: response_time, error: inspect(reason)}}
      end
    rescue
      e ->
        response_time = System.monotonic_time(:millisecond) - start_time
        {region, %{status: "down", response_time: response_time, error: Exception.message(e)}}
    end
  end

  @doc "Benchmark: spawn N fake monitors, measure memory. Called via :erpc."
  def bench(target) do
    current = Registry.count(UptrackWorker.Monitoring.MonitorRegistry)

    # Clean previous bench monitors
    if current > 20 do
      for i <- 1..current do
        UptrackWorker.Monitoring.MonitorSupervisor.stop_monitor("bench-#{i}")
      end
      Process.sleep(1000)
    end

    before_mem = :erlang.memory(:total)
    before_procs = :erlang.system_info(:process_count)

    # Spawn all at once with localhost URL (no real connection)
    for i <- 1..target do
      m = %{
        id: "bench-#{i}", name: "bench-#{i}",
        url: "http://127.0.0.1:1",
        interval: 999_999, timeout: 1, status: "active",
        settings: %{}, confirmation_threshold: 3, organization_id: "bench"
      }
      UptrackWorker.Monitoring.MonitorSupervisor.start_monitor(m)
    end

    Process.sleep(3000)

    after_mem = :erlang.memory()
    after_procs = :erlang.system_info(:process_count)
    reg = Registry.count(UptrackWorker.Monitoring.MonitorRegistry)

    %{
      target: target,
      registry: reg,
      beam_procs: after_procs,
      total_mb: Float.round(after_mem[:total] / 1_048_576, 1),
      proc_mb: Float.round(after_mem[:processes] / 1_048_576, 1),
      delta_mb: Float.round((after_mem[:total] - before_mem) / 1_048_576, 1),
      per_monitor_kb: Float.round((after_mem[:total] - before_mem) / target / 1024, 1)
    }
  end

  @doc "Cleanup all bench monitors"
  def bench_cleanup do
    count = Registry.count(UptrackWorker.Monitoring.MonitorRegistry)
    for i <- 1..count do
      UptrackWorker.Monitoring.MonitorSupervisor.stop_monitor("bench-#{i}")
    end
    :ok
  end
end
