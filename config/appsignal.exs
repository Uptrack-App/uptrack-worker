import Config

# Worker AppSignal: separate namespace so errors and perf metrics from the
# check worker are distinguishable from the API. Error backend must be set
# explicitly — it defaults to false in AppSignal 2.17+.
#
# push_api_key: shared with API for now (we only use one AppSignal app).
# Override at runtime via APPSIGNAL_PUSH_API_KEY in runtime.exs.
config :appsignal, :config,
  otp_app: :uptrack_worker,
  name: "Uptrack Worker",
  push_api_key: System.get_env("APPSIGNAL_PUSH_API_KEY"),
  env: Mix.env(),
  enable_error_backend: true
