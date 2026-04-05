import Config

if config_env() == :prod do
  # Region override from env var
  if region = System.get_env("NODE_REGION") do
    config :uptrack_worker, node_region: String.to_existing_atom(region)
  end

  # libcluster topology for Tailscale mesh
  config :libcluster,
    topologies: [
      tailscale: [
        strategy: Cluster.Strategy.Gossip,
        config: [
          port: 45892,
          if_addr: {0, 0, 0, 0},
          multicast_if: {0, 0, 0, 0}
        ]
      ]
    ]
end
