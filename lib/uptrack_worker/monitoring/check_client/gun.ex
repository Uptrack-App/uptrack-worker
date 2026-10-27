defmodule UptrackWorker.Monitoring.CheckClient.Gun do
  @moduledoc """
  Gun-based HTTP check client with persistent connections.
  Adapted from Uptrack.Monitoring.CheckClient.Gun.
  """

  @behaviour UptrackWorker.Monitoring.CheckClient

  alias UptrackWorker.Monitoring.CheckClient.RequestGuard
  alias UptrackWorker.Monitoring.GunConnection

  @impl true
  def open_connection(monitor) do
    GunConnection.open(monitor.url, timeout: (monitor.timeout || 30) * 1000)
  end

  @impl true
  def close_connection(conn), do: GunConnection.close(conn)

  @impl true
  def check(monitor, %GunConnection{} = conn) do
    request = build_request(monitor)

    case RequestGuard.validate(request) do
      :ok ->
        start_time = System.monotonic_time(:millisecond)
        result = execute_request(conn, request, (monitor.timeout || 30) * 1000)
        response_time = System.monotonic_time(:millisecond) - start_time
        build_check_attrs(monitor, result, response_time)

      {:error, message} ->
        build_check_attrs(monitor, {:error, message}, 0)
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

  # --- Pure functions ---

  def build_request(monitor) do
    uri = URI.parse(monitor.url)
    path = (uri.path || "/") <> if(uri.query, do: "?#{uri.query}", else: "")
    settings = monitor.settings || %{}
    raw_method = Map.get(settings, "method", "GET")

    # Allowlisted atom, never String.to_atom on customer input. An unknown
    # method stays as the raw value so RequestGuard.validate/1 rejects it.
    method =
      case RequestGuard.parse_method(raw_method) do
        {:ok, atom} -> atom
        :error -> raw_method
      end

    headers = build_headers(monitor)
    %{method: method, path: path, headers: headers}
  end

  def build_headers(monitor) do
    base = [{"user-agent", "Uptrack Monitor/1.0"}, {"accept", "*/*"}]

    case Map.get(monitor.settings || %{}, "headers") do
      nil ->
        base

      custom when is_map(custom) ->
        Enum.reduce(custom, base, fn {k, v}, acc -> [{k, v} | acc] end)

      _ ->
        base
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

  # --- Impure boundary ---

  defp execute_request(%GunConnection{pid: pid}, request, timeout) do
    stream_ref = :gun.request(pid, method_string(request.method), request.path, request.headers)

    case :gun.await(pid, stream_ref, timeout) do
      {:response, :fin, status, headers} ->
        {:ok, status, headers, ""}

      {:response, :nofin, status, headers} ->
        case :gun.await_body(pid, stream_ref, timeout) do
          {:ok, body} -> {:ok, status, headers, body}
          {:error, reason} -> {:error, "Body read: #{inspect(reason)}"}
        end

      {:error, reason} ->
        {:error, "Request failed: #{inspect(reason)}"}
    end
  rescue
    e -> {:error, "Check error: #{Exception.message(e)}"}
  catch
    :exit, reason -> {:error, "Connection lost: #{inspect(reason)}"}
  end

  defp method_string(:get), do: "GET"
  defp method_string(:post), do: "POST"
  defp method_string(:put), do: "PUT"
  defp method_string(:head), do: "HEAD"
  defp method_string(:delete), do: "DELETE"
  defp method_string(:patch), do: "PATCH"
  defp method_string(:options), do: "OPTIONS"

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
