defmodule UptrackWorker.Monitoring.HttpCheck do
  @moduledoc """
  Raw Mint-based HTTP check with redirect following.

  Opens a fresh connection per check — no pool, no persistent state.
  Follows redirects up to 5 hops. Supports custom headers, methods, and body.
  """

  @user_agent "Uptrack Monitor/1.0"
  @max_redirects 5

  @redirect_statuses [301, 302, 303, 307, 308]

  @doc """
  Performs an HTTP check against the given URL.

  Returns `{:ok, status_code, headers, body}` or `{:error, reason}`.
  Follows redirects automatically (301, 302, 303, 307, 308) up to 5 hops.
  """
  def check(url, opts \\ []) do
    method = Keyword.get(opts, :method, "GET")
    headers = Keyword.get(opts, :headers, [])
    body = Keyword.get(opts, :body)
    timeout = Keyword.get(opts, :timeout, 30_000)

    request_with_redirects(method, url, headers, body, timeout, 0)
  end

  defp request_with_redirects(_method, _url, _headers, _body, _timeout, hops)
       when hops >= @max_redirects do
    {:error, "Too many redirects (max #{@max_redirects})"}
  end

  defp request_with_redirects(method, url, headers, body, timeout, hops) do
    uri = URI.parse(url)
    scheme = if uri.scheme == "https", do: :https, else: :http
    host = uri.host || "localhost"
    port = uri.port || if(scheme == :https, do: 443, else: 80)
    path = (uri.path || "/") <> if(uri.query, do: "?" <> uri.query, else: "")

    request_headers = build_headers(headers, host)
    mint_method = String.upcase(to_string(method))

    with {:ok, conn} <- connect(scheme, host, port, timeout),
         {:ok, conn, ref} <- send_request(conn, mint_method, path, request_headers, body),
         {:ok, _conn, status, resp_headers, resp_body} <- collect_response(conn, ref, timeout) do
      if status in @redirect_statuses and hops < @max_redirects do
        case get_location(resp_headers) do
          nil ->
            {:ok, status, normalize_headers(resp_headers), resp_body}

          location ->
            redirect_url = resolve_redirect(url, location)
            redirect_method = redirect_method(method, status)
            redirect_body = if redirect_method == "GET", do: nil, else: body
            request_with_redirects(redirect_method, redirect_url, headers, redirect_body, timeout, hops + 1)
        end
      else
        {:ok, status, normalize_headers(resp_headers), resp_body}
      end
    else
      {:error, _conn, reason} -> {:error, format_error(reason)}
      {:error, reason} -> {:error, format_error(reason)}
    end
  end

  defp connect(scheme, host, port, timeout) do
    transport_opts =
      if scheme == :https do
        [verify: :verify_peer, cacerts: :public_key.cacerts_get(), depth: 3,
         customize_hostname_check: [
           match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
         ]]
      else
        []
      end

    case Mint.HTTP.connect(scheme, host, port,
           transport_opts: transport_opts,
           timeout: timeout,
           mode: :passive) do
      {:ok, conn} -> {:ok, conn}
      {:error, reason} -> {:error, reason}
    end
  end

  defp send_request(conn, method, path, headers, body) do
    case Mint.HTTP.request(conn, method, path, headers, body) do
      {:ok, conn, ref} -> {:ok, conn, ref}
      {:error, conn, reason} -> {:error, conn, reason}
    end
  end

  defp collect_response(conn, ref, timeout) do
    collect_response(conn, ref, timeout, nil, [], [])
  end

  defp collect_response(conn, ref, timeout, status, headers, body_parts) do
    case Mint.HTTP.recv(conn, 0, timeout) do
      {:ok, conn, responses} ->
        {status, headers, body_parts, done?} =
          Enum.reduce(responses, {status, headers, body_parts, false}, fn
            {:status, ^ref, s}, {_, h, b, _} -> {s, h, b, false}
            {:headers, ^ref, h}, {s, acc_h, b, _} -> {s, acc_h ++ h, b, false}
            {:data, ^ref, d}, {s, h, b, _} -> {s, h, [d | b], false}
            {:done, ^ref}, {s, h, b, _} -> {s, h, b, true}
            _, acc -> acc
          end)

        if done? do
          Mint.HTTP.close(conn)
          body = body_parts |> Enum.reverse() |> IO.iodata_to_binary()
          {:ok, conn, status, headers, body}
        else
          collect_response(conn, ref, timeout, status, headers, body_parts)
        end

      {:error, conn, reason, _responses} ->
        Mint.HTTP.close(conn)
        {:error, conn, reason}
    end
  end

  # --- Pure functions ---

  defp build_headers(custom_headers, host) do
    base = [{"user-agent", @user_agent}, {"accept", "*/*"}, {"host", host}]

    custom_headers
    |> Enum.reduce(base, fn {key, value}, acc ->
      [{String.downcase(key), value} | acc]
    end)
    |> Enum.reverse()
  end

  defp get_location(headers) do
    Enum.find_value(headers, fn
      {key, value} -> if String.downcase(key) == "location", do: value
    end)
  end

  defp resolve_redirect(original_url, location) do
    case URI.parse(location) do
      %URI{host: nil} ->
        original_uri = URI.parse(original_url)
        URI.to_string(%{original_uri | path: location, query: nil, fragment: nil})

      %URI{scheme: nil} ->
        original_uri = URI.parse(original_url)
        URI.to_string(%{URI.parse(location) | scheme: original_uri.scheme})

      _absolute ->
        location
    end
  end

  defp redirect_method(method, status) when status in [301, 302] do
    m = String.upcase(to_string(method))
    if m in ["GET", "HEAD"], do: m, else: "GET"
  end

  defp redirect_method(_method, 303), do: "GET"

  defp redirect_method(method, _status) do
    String.upcase(to_string(method))
  end

  defp normalize_headers(headers) do
    Map.new(headers, fn {key, value} -> {String.downcase(to_string(key)), value} end)
  end

  defp format_error(%Mint.TransportError{reason: reason}), do: "Transport error: #{inspect(reason)}"
  defp format_error(%Mint.HTTPError{reason: reason}), do: "HTTP error: #{inspect(reason)}"
  defp format_error(reason) when is_atom(reason), do: "#{reason}"
  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)
end
