defmodule UptrackWorker.Monitoring.MonitorSupervisor do
  @moduledoc """
  DynamicSupervisor managing all MonitorProcess instances.

  Simplified from main app — no hash partitioning (worker runs ALL monitors).
  Monitor list comes from MonitorSync via RPC to the main app.
  """

  use DynamicSupervisor

  alias UptrackWorker.Monitoring.{MonitorProcess, MonitorRegistry}

  require Logger

  def start_link(_opts) do
    DynamicSupervisor.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @impl true
  def init(:ok) do
    DynamicSupervisor.init(
      strategy: :one_for_one,
      max_restarts: 1000,
      max_seconds: 5
    )
  end

  def start_monitor(monitor) do
    case DynamicSupervisor.start_child(__MODULE__, {MonitorProcess, monitor}) do
      {:ok, pid} ->
        Logger.debug("Started MonitorProcess for #{monitor.id}")
        {:ok, pid}

      {:error, {:already_started, pid}} ->
        {:ok, pid}

      {:error, reason} ->
        Logger.error("Failed to start MonitorProcess for #{monitor.id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  def stop_monitor(monitor_id) do
    case MonitorRegistry.lookup(monitor_id) do
      {:ok, pid} -> DynamicSupervisor.terminate_child(__MODULE__, pid)
      :error -> :ok
    end
  end

  def count, do: MonitorRegistry.count()
end
