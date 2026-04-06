defmodule UptrackWorker.Monitoring.CheckExecutor do
  @moduledoc """
  Executes a monitoring check and returns a result map.

  Uses raw Mint HTTP with fresh connections per check — no pool.
  Worker only does HTTP/HTTPS checks (SSL/TCP/DNS handled by main app).
  """

  alias UptrackWorker.Monitoring.{HttpCheck, Assertions}

  def execute(monitor) do
    settings = monitor.settings || %{}
    headers = case Map.get(settings, "headers") do
      nil -> []
      custom when is_map(custom) -> Enum.to_list(custom)
      _ -> []
    end

    method = Map.get(settings, "method", "GET")
    timeout = (monitor.timeout || 30) * 1000

    body =
      case {method, Map.get(settings, "body")} do
        {m, b} when m in ["POST", "PUT", "PATCH", "post", "put", "patch"]
                     and is_binary(b) and b != "" -> b
        _ -> nil
      end

    start_time = System.monotonic_time(:millisecond)

    result = HttpCheck.check(monitor.url,
      method: method,
      headers: headers,
      body: body,
      timeout: timeout
    )

    response_time = System.monotonic_time(:millisecond) - start_time

    build_check_attrs(monitor, result, response_time)
  end

  defp build_check_attrs(monitor, {:ok, status_code, headers, body}, response_time) do
    expected = Map.get(monitor.settings || %{}, "expected_status_code")
    assertions = Map.get(monitor.settings || %{}, "assertions", [])

    base = %{
      monitor_id: monitor.id,
      response_time: response_time,
      status_code: status_code,
      checked_at: DateTime.utc_now() |> DateTime.truncate(:second),
      response_headers: headers,
      response_body: truncate_body(body)
    }

    cond do
      expected && status_code != expected ->
        Map.merge(base, %{status: "down", error_message: "Expected #{expected}, got #{status_code}"})

      assertions != [] ->
        case Assertions.evaluate(assertions, status_code, headers, body) do
          :ok -> Map.put(base, :status, "up")
          {:error, msg} -> Map.merge(base, %{status: "down", error_message: "Assertion: #{msg}"})
        end

      true ->
        Map.put(base, :status, "up")
    end
  end

  defp build_check_attrs(monitor, {:error, reason}, response_time) do
    %{
      monitor_id: monitor.id,
      status: "down",
      response_time: response_time,
      checked_at: DateTime.utc_now() |> DateTime.truncate(:second),
      error_message: to_string(reason)
    }
  end

  defp truncate_body(nil), do: nil
  defp truncate_body(body) when is_binary(body) and byte_size(body) > 1000 do
    binary_part(body, 0, 1000) <> "... [truncated]"
  end
  defp truncate_body(body) when is_binary(body), do: body
  defp truncate_body(_), do: nil
end
