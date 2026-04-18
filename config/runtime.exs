import Config

if config_env() == :prod do
  # Region override from env var
  if region = System.get_env("NODE_REGION") do
    config :uptrack_worker, node_region: region
  end

  # AppSignal: runtime override for push API key (falls back to compile-time
  # default in config/appsignal.exs when env var isn't set).
  if key = System.get_env("APPSIGNAL_PUSH_API_KEY") do
    config :appsignal, :config, push_api_key: key
  end

  # Erlang cluster: connect to main app nodes via static node list
  # MAIN_NODES env var: comma-separated, e.g. "uptrack@REMOVED_MAIN_TS_IP_1,uptrack@REMOVED_MAIN_TS_IP_2"
  if nodes = System.get_env("MAIN_NODES") do
    node_list =
      nodes
      |> String.split(",", trim: true)
      |> Enum.map(&String.to_atom(String.trim(&1)))

    config :libcluster,
      topologies: [
        static: [
          strategy: Cluster.Strategy.Epmd,
          config: [hosts: node_list]
        ]
      ]
  end
end
