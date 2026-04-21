import Config

config :atlas, Atlas.Repo,
  database: "priv/data/projection.db",
  stacktrace: true,
  show_sensitive_data_on_connection_error: true,
  log: false

config :logger, level: :info
