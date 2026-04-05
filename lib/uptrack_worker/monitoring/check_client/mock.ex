defmodule UptrackWorker.Monitoring.CheckClient.Mock do
  @moduledoc "Mock check client for tests."

  @behaviour UptrackWorker.Monitoring.CheckClient

  @impl true
  def open_connection(_monitor), do: {:ok, :mock_conn}

  @impl true
  def close_connection(_conn), do: :ok

  @impl true
  def check(monitor, _conn) do
    result = Process.get(:mock_check_result, %{status: "up"})

    Map.merge(
      %{
        monitor_id: monitor.id,
        status: "up",
        response_time: 50,
        checked_at: DateTime.utc_now() |> DateTime.truncate(:second)
      },
      result
    )
  end
end
