import Config

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :atlas_web, AtlasWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "17zJLu4zod/Gz5x3CLfPAaoKrLB4swEFlZ63SGoK1DVCj92d4N8EGLH24ulTkWk+",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

# Each test run uses a disposable temp directory.
# `Atlas.Test.DataCase` rewrites paths at setup; this is a safe default.
config :atlas,
  data_dir: "data/test"

config :atlas, Atlas.Repo,
  database: "data/test/projection.db",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 5

config :logger, level: :warning
