defmodule UptrackWorker.Monitoring.CheckClient.RequestGuard do
  @moduledoc """
  Pure validation of a built HTTP request before it reaches `:gun.request/4`.

  The request path/query comes from `monitor.url` and header names/values and
  the method from `monitor.settings`, all customer-controlled. gun (GHSA-w4f7-4cxr-rv3c)
  does not reject CR, LF or NUL in them, so a customer could split the request.
  This guard rejects such input. Error messages never echo the offending value.
  """

  @methods [:get, :head, :post, :put, :patch, :delete, :options]
  @method_strings Map.new(@methods, &{Atom.to_string(&1), &1})

  @doc "Allowed request methods, as atoms."
  def methods, do: @methods

  @doc """
  Maps a method name (case-insensitive) to an allowlisted atom without
  creating atoms. Returns `{:ok, atom}` or `:error`.
  """
  def parse_method(method) when is_binary(method) do
    case Map.fetch(@method_strings, String.downcase(method)) do
      {:ok, _} = ok -> ok
      :error -> :error
    end
  end

  def parse_method(_), do: :error

  @doc """
  Validates a `%{method: _, path: _, headers: _}` request map.

  Returns `:ok` or `{:error, message}` with a fixed message.
  """
  @spec validate(map()) :: :ok | {:error, String.t()}
  def validate(%{method: method, path: path, headers: headers}) do
    cond do
      method not in @methods -> {:error, "invalid request: unsupported HTTP method"}
      not is_binary(path) -> {:error, "invalid request: path is not a string"}
      unsafe?(path) -> {:error, "invalid request: path contains CR/LF/NUL"}
      true -> validate_headers(headers)
    end
  end

  def validate(_), do: {:error, "invalid request: malformed request"}

  defp validate_headers(headers) do
    Enum.find_value(headers, :ok, fn
      {name, value} when is_binary(name) and is_binary(value) ->
        cond do
          unsafe?(name) -> {:error, "invalid request: header name contains CR/LF/NUL"}
          unsafe?(value) -> {:error, "invalid request: header value contains CR/LF/NUL"}
          true -> nil
        end

      _ ->
        {:error, "invalid request: header name or value is not a string"}
    end)
  end

  defp unsafe?(binary), do: :binary.match(binary, ["\r", "\n", <<0>>]) != :nomatch
end
