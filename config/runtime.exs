import Config

if config_env() == :prod do
  # Region override from env var
  if region = System.get_env("NODE_REGION") do
    config :uptrack_worker, node_region: region
  end

  # Erlang cluster: connect to main app nodes via static node list
  # MAIN_NODES env var: comma-separated, e.g. "uptrack@100.64.1.1,uptrack@100.64.1.2"
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
