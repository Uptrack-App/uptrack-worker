defmodule UptrackWorker.Monitoring.CheckClient do
  @moduledoc "Behaviour for HTTP check implementations."

  @type check_result :: %{
    status: String.t(),
    status_code: integer() | nil,
    response_time: integer(),
    response_headers: map(),
    response_body: String.t() | nil,
    error_message: String.t() | nil,
    checked_at: DateTime.t(),
    monitor_id: String.t()
  }

  @callback check(monitor :: map(), conn :: term()) :: check_result()
  @callback open_connection(monitor :: map()) :: {:ok, term()} | {:error, term()}
  @callback close_connection(conn :: term()) :: :ok
end
