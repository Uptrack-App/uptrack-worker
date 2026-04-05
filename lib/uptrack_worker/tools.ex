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
end
