import Config

# Each test run uses a disposable temp directory.
# `Atlas.Test.DataCase` rewrites paths at setup; this is a safe default.
config :atlas,
  data_dir: "priv/data/test"

config :atlas, Atlas.Repo,
  database: "priv/data/test/projection.db",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 5

config :logger, level: :warning
