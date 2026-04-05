defmodule UptrackWorker.Monitoring.GunConnection do
  @moduledoc """
  Manages a Gun HTTP connection lifecycle.
  Identical to Uptrack.Monitoring.GunConnection.
  """

  defstruct [:pid, :ref, :host, :port, :tls?, state: :disconnected]

  @type t :: %__MODULE__{
    pid: pid() | nil,
    ref: reference() | nil,
    host: charlist(),
    port: integer(),
    tls?: boolean(),
    state: :connecting | :connected | :disconnected
  }

  @spec open(String.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def open(url, opts \\ []) do
    uri = URI.parse(url)
    host = String.to_charlist(uri.host || "localhost")
    port = uri.port || if(uri.scheme == "https", do: 443, else: 80)
    tls? = uri.scheme == "https"

    gun_opts = build_opts(tls?, opts)

    case :gun.open(host, port, gun_opts) do
      {:ok, pid} ->
        ref = Process.monitor(pid)
        {:ok, %__MODULE__{
          pid: pid, ref: ref,
          host: host, port: port,
          tls?: tls?, state: :connecting
        }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec close(t()) :: :ok
  def close(%__MODULE__{pid: nil}), do: :ok
  def close(%__MODULE__{pid: pid}) do
    :gun.close(pid)
    :ok
  end

  def connected(%__MODULE__{} = conn), do: %{conn | state: :connected}
  def disconnected(%__MODULE__{} = conn), do: %{conn | state: :disconnected}
  def connected?(%__MODULE__{state: :connected}), do: true
  def connected?(_), do: false

  defp build_opts(true = _tls?, opts) do
    timeout = Keyword.get(opts, :timeout, 30_000)
    %{
      connect_timeout: timeout,
      retry: 5,
      retry_timeout: 5_000,
      protocols: [:http],
      transport: :tls,
      tls_opts: [
        verify: :verify_peer,
        cacerts: :public_key.cacerts_get(),
        depth: 3,
        customize_hostname_check: [
          match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
        ]
      ]
    }
  end

  defp build_opts(false, opts) do
    timeout = Keyword.get(opts, :timeout, 30_000)
    %{
      connect_timeout: timeout,
      retry: 5,
      retry_timeout: 5_000,
      protocols: [:http]
    }
  end
end
