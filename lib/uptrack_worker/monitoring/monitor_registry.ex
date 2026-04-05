defmodule UptrackWorker.Monitoring.MonitorRegistry do
  @moduledoc "Registry for looking up MonitorProcess by monitor_id."

  def child_spec(_opts) do
    Registry.child_spec(keys: :unique, name: __MODULE__)
  end

  def via(monitor_id) do
    {:via, Registry, {__MODULE__, monitor_id}}
  end

  def lookup(monitor_id) do
    case Registry.lookup(__MODULE__, monitor_id) do
      [{pid, _}] -> {:ok, pid}
      [] -> :error
    end
  end

  def all_ids do
    Registry.select(__MODULE__, [{{:"$1", :_, :_}, [], [:"$1"]}])
  end

  def count do
    Registry.count(__MODULE__)
  end
end
