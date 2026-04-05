defmodule UptrackWorker.Application do
  @moduledoc """
  Minimal check worker application.

  Runs MonitorProcess GenServers that perform HTTP checks and broadcast
  results via pg. No Phoenix, no Oban, no database.
  """

  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    topologies = Application.get_env(:libcluster, :topologies, [])

    children = [
      # Cluster formation (libcluster over Tailscale)
      {Cluster.Supervisor, [topologies, [name: UptrackWorker.ClusterSupervisor]]},
      # pg scopes for multi-region consensus and config sync
      %{id: :monitor_checks_pg, start: {:pg, :start_link, [:monitor_checks]}},
      %{id: :monitor_config_pg, start: {:pg, :start_link, [:monitor_config]}},
      # Task supervisor for async checks
      {Task.Supervisor, name: UptrackWorker.TaskSupervisor},
      # Registry for monitor process lookup
      UptrackWorker.Monitoring.MonitorRegistry,
      # DynamicSupervisor for per-monitor GenServer processes
      UptrackWorker.Monitoring.MonitorSupervisor,
      # Syncs monitor list from main app on cluster join
      UptrackWorker.Monitoring.MonitorSync
    ]

    opts = [strategy: :one_for_one, name: UptrackWorker.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
