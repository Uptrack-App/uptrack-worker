defmodule UptrackWorker.Monitoring.Assertions do
  @moduledoc """
  Pure response assertion evaluation.
  Identical to Uptrack.Monitoring.Assertions.
  """

  def evaluate(assertions, status_code, headers, body) when is_list(assertions) do
    Enum.reduce_while(assertions, :ok, fn assertion, :ok ->
      case evaluate_one(assertion, status_code, headers, body) do
        :ok -> {:cont, :ok}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  def evaluate(_, _, _, _), do: :ok

  defp evaluate_one(%{"type" => "json_path"} = assertion, _status, _headers, body) do
    target = assertion["target"]
    operator = assertion["operator"] || "eq"
    expected = assertion["value"]

    case json_path_query(body, target) do
      {:ok, actual} -> compare(actual, operator, expected, "JSONPath #{target}")
      {:error, reason} -> {:error, "JSONPath #{target}: #{reason}"}
    end
  end

  defp evaluate_one(%{"type" => "header"} = assertion, _status, headers, _body) do
    target = String.downcase(assertion["target"] || "")
    operator = assertion["operator"] || "contains"
    expected = assertion["value"] || ""

    header_value =
      headers
      |> Enum.find_value(fn
        {k, v} when is_binary(k) -> if String.downcase(k) == target, do: v
        _ -> nil
      end)

    if is_nil(header_value) do
      {:error, "Header '#{target}' not found in response"}
    else
      compare(header_value, operator, expected, "Header #{target}")
    end
  end

  defp evaluate_one(%{"type" => "status_code"} = assertion, status_code, _headers, _body) do
    operator = assertion["operator"] || "eq"
    expected = assertion["value"]
    compare(to_string(status_code), operator, to_string(expected), "Status code")
  end

  defp evaluate_one(%{"type" => "regex"} = assertion, _status, _headers, body) do
    pattern = assertion["target"] || ""

    case Regex.compile(pattern) do
      {:ok, regex} ->
        if Regex.match?(regex, body || ""),
          do: :ok,
          else: {:error, "Regex /#{pattern}/ did not match response body"}
      {:error, _} ->
        {:error, "Invalid regex pattern: #{pattern}"}
    end
  end

  defp evaluate_one(%{"type" => "contains"} = assertion, _status, _headers, body) do
    target = assertion["target"] || ""
    if String.contains?(body || "", target), do: :ok, else: {:error, "Response body does not contain '#{target}'"}
  end

  defp evaluate_one(%{"type" => "not_contains"} = assertion, _status, _headers, body) do
    target = assertion["target"] || ""
    if String.contains?(body || "", target),
      do: {:error, "Response body contains '#{target}' (expected it not to)"},
      else: :ok
  end

  defp evaluate_one(%{"type" => type}, _status, _headers, _body) do
    {:error, "Unknown assertion type: #{type}"}
  end

  defp evaluate_one(_, _status, _headers, _body), do: :ok

  defp compare(actual, "eq", expected, label) do
    if to_string(actual) == to_string(expected), do: :ok,
      else: {:error, "#{label}: expected #{inspect(expected)}, got #{inspect(actual)}"}
  end

  defp compare(actual, "neq", expected, label) do
    if to_string(actual) != to_string(expected), do: :ok,
      else: {:error, "#{label}: expected not #{inspect(expected)}, but got #{inspect(actual)}"}
  end

  defp compare(actual, "contains", expected, label) do
    if String.contains?(to_string(actual), to_string(expected)), do: :ok,
      else: {:error, "#{label}: #{inspect(actual)} does not contain #{inspect(expected)}"}
  end

  defp compare(actual, "not_contains", expected, label) do
    if String.contains?(to_string(actual), to_string(expected)),
      do: {:error, "#{label}: #{inspect(actual)} should not contain #{inspect(expected)}"},
      else: :ok
  end

  defp compare(_actual, "matches", _expected, label) do
    {:error, "#{label}: 'matches' operator requires 'regex' assertion type"}
  end

  defp compare(actual, op, expected, label) when op in ["gt", "lt", "gte", "lte"] do
    with {actual_num, _} <- Float.parse(to_string(actual)),
         {expected_num, _} <- Float.parse(to_string(expected)) do
      result = case op do
        "gt" -> actual_num > expected_num
        "lt" -> actual_num < expected_num
        "gte" -> actual_num >= expected_num
        "lte" -> actual_num <= expected_num
      end

      if result, do: :ok, else: {:error, "#{label}: #{actual_num} is not #{op} #{expected_num}"}
    else
      _ -> {:error, "#{label}: cannot compare non-numeric values with #{op}"}
    end
  end

  defp compare(_actual, op, _expected, label) do
    {:error, "#{label}: unknown operator '#{op}'"}
  end

  def json_path_query(body, path) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, data} -> json_path_query(data, path)
      {:error, _} -> {:error, "Response body is not valid JSON"}
    end
  end

  def json_path_query(data, "$" <> rest), do: navigate(data, parse_path(rest))
  def json_path_query(data, path), do: navigate(data, parse_path(path))

  defp parse_path(""), do: []
  defp parse_path("." <> rest), do: parse_path(rest)

  defp parse_path(path) do
    case Regex.run(~r/^([^\.\[\]]+)(.*)$/, path) do
      [_, key, rest] -> [key | parse_path(rest)]
      _ ->
        case Regex.run(~r/^\[(\d+)\](.*)$/, path) do
          [_, index, rest] -> [{:index, String.to_integer(index)} | parse_path(rest)]
          _ -> [path]
        end
    end
  end

  defp navigate(data, []), do: {:ok, data}

  defp navigate(data, [{:index, idx} | rest]) when is_list(data) do
    case Enum.at(data, idx) do
      nil -> {:error, "Array index [#{idx}] out of bounds"}
      value -> navigate(value, rest)
    end
  end

  defp navigate(data, [key | rest]) when is_map(data) do
    case Map.fetch(data, key) do
      {:ok, value} -> navigate(value, rest)
      :error -> {:error, "Key '#{key}' not found"}
    end
  end

  defp navigate(_data, [key | _rest]) do
    {:error, "Cannot access '#{key}' on non-map/list value"}
  end
end
