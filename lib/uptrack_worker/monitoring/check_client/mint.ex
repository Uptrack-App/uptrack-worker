defmodule UptrackWorker.Monitoring.CheckClient.Mint do
  @moduledoc """
  Mint-based HTTP check client. Process-less persistent connections.

  3.9x less RAM per connection vs Gun (200KB vs 774KB).
  Same throughput (~111ms/req).

  ## Pipeline
      build_request → execute_request (send + collect) → build_check_attrs
  """

  @behaviour UptrackWorker.Monitoring.CheckClient

  alias UptrackWorker.Monitoring.MintConnection

  @impl true
  def open_connection(monitor) do
    MintConnection.open(monitor.url, timeout: (monitor.timeout || 30) * 1000)
  end

  @impl true
  def close_connection(%MintConnection{} = mc) do
    MintConnection.close(mc)
  end

  def close_connection(_), do: :ok

  @impl true
  def check(monitor, %MintConnection{} = mc) do
    request = build_request(monitor)
    start_time = System.monotonic_time(:millisecond)
    timeout = (monitor.timeout || 30) * 1000

    case MintConnection.request(mc, request.method, request.path, request.headers) do
      {:ok, mc, ref} ->
        case collect_response(mc, ref, timeout) do
          {:ok, mc, status, headers, body} ->
            response_time = System.monotonic_time(:millisecond) - start_time
            result = build_check_attrs(monitor, {:ok, status, headers, body}, response_time)
            # Return result + updated connection for MonitorProcess to store
            %{result | __mint_conn__: mc}

          {:error, mc, reason} ->
            response_time = System.monotonic_time(:millisecond) - start_time
            result = build_check_attrs(monitor, {:error, reason}, response_time)
            %{result | __mint_conn__: mc}
        end

      {:error, mc, reason} ->
        result = %{
          monitor_id: monitor.id,
          status: "down",
          response_time: 0,
          checked_at: DateTime.utc_now() |> DateTime.truncate(:second),
          error_message: "Connection error: #{inspect(reason)}",
          __mint_conn__: mc
        }
        result
    end
  end

  def check(monitor, _conn) do
    %{
      monitor_id: monitor.id,
      status: "down",
      response_time: 0,
      checked_at: DateTime.utc_now() |> DateTime.truncate(:second),
      error_message: "No connection to target host"
    }
  end

  # --- Response collection ---

  defp collect_response(mc, ref, timeout) do
    collect_response(mc, ref, timeout, nil, [], [])
  end

  defp collect_response(mc, ref, timeout, status, headers, body_parts) do
    receive do
      msg ->
        case MintConnection.stream(mc, msg) do
          {:ok, mc, responses} ->
            {status, headers, body_parts, done?} =
              Enum.reduce(responses, {status, headers, body_parts, false}, fn
                {:status, ^ref, s}, {_, h, b, _} -> {s, h, b, false}
                {:headers, ^ref, h}, {s, _, b, _} -> {s, h, b, false}
                {:data, ^ref, d}, {s, h, b, _} -> {s, h, [d | b], false}
                {:done, ^ref}, {s, h, b, _} -> {s, h, b, true}
                _, acc -> acc
              end)

            if done? do
              body = body_parts |> Enum.reverse() |> IO.iodata_to_binary()
              {:ok, mc, status, headers, body}
            else
              collect_response(mc, ref, timeout, status, headers, body_parts)
            end

          {:error, mc, reason, _responses} ->
            {:error, mc, reason}

          :unknown ->
            collect_response(mc, ref, timeout, status, headers, body_parts)
        end
    after
      timeout -> {:error, mc, :timeout}
    end
  end

  # --- Pure functions (shared with Gun) ---

  def build_request(monitor) do
    uri = URI.parse(monitor.url)
    path = (uri.path || "/") <> if(uri.query, do: "?#{uri.query}", else: "")
    settings = monitor.settings || %{}
    method = Map.get(settings, "method", "GET")
    headers = build_headers(monitor)
    %{method: method, path: path, headers: headers}
  end

  def build_headers(monitor) do
    base = [{"user-agent", "Uptrack Monitor/1.0"}, {"accept", "*/*"}]

    case Map.get(monitor.settings || %{}, "headers") do
      nil -> base
      custom when is_map(custom) ->
        Enum.reduce(custom, base, fn {k, v}, acc -> [{k, v} | acc] end)
      _ -> base
    end
  end

  def build_check_attrs(monitor, {:ok, status, headers, body}, response_time) do
    expected = Map.get(monitor.settings || %{}, "expected_status_code")
    assertions = Map.get(monitor.settings || %{}, "assertions", [])

    base = %{
      monitor_id: monitor.id,
      response_time: response_time,
      status_code: status,
      checked_at: DateTime.utc_now() |> DateTime.truncate(:second),
      response_headers: normalize_headers(headers),
      response_body: truncate_body(body)
    }

    cond do
      expected && status != expected ->
        Map.merge(base, %{status: "down", error_message: "Expected #{expected}, got #{status}"})

      assertions != [] ->
        case UptrackWorker.Monitoring.Assertions.evaluate(assertions, status, headers, body) do
          :ok -> Map.put(base, :status, "up")
          {:error, msg} -> Map.merge(base, %{status: "down", error_message: "Assertion: #{msg}"})
        end

      true ->
        Map.put(base, :status, "up")
    end
  end

  def build_check_attrs(monitor, {:error, reason}, response_time) do
    %{
      monitor_id: monitor.id,
      status: "down",
      response_time: response_time,
      checked_at: DateTime.utc_now() |> DateTime.truncate(:second),
      error_message: to_string(reason)
    }
  end

  defp normalize_headers(headers) do
    Map.new(headers, fn {k, v} -> {to_string(k), to_string(v)} end)
  end

  defp truncate_body(nil), do: nil
  defp truncate_body(body) when is_binary(body) and byte_size(body) > 1000 do
    binary_part(body, 0, 1000) <> "... [truncated]"
  end
  defp truncate_body(body) when is_binary(body), do: body
  defp truncate_body(_), do: nil
end
