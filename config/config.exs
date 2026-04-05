import Config

config :uptrack_worker,
  node_region: "us",
  check_client: UptrackWorker.Monitoring.CheckClient.Mint

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

import_config "#{config_env()}.exs"
