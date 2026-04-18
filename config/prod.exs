import Config

config :logger, level: :info

# Activate AppSignal in prod (inactive by default in dev/test so local runs
# don't push metrics to production)
config :appsignal, :config, active: true
