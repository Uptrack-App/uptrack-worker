import Config

config :uptrack_worker,
  check_client: UptrackWorker.Monitoring.CheckClient.Mock

config :logger, level: :warning
