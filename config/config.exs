import Config

config :atlas,
  ecto_repos: [Atlas.Repo],
  # Root for runtime state: store chunks, log DB, projection DB.
  data_dir: "priv/data"

config :atlas, Atlas.Repo,
  database: "priv/data/projection.db",
  pool_size: 5,
  journal_mode: :wal,
  cache_size: -64_000,
  temp_store: :memory,
  show_sensitive_data_on_connection_error: false

config :logger, :console,
  format: "$time [$level] $metadata$message\n",
  metadata: [:request_id, :module]

import_config "#{config_env()}.exs"
