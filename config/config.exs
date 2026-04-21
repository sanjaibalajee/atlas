# Umbrella-level configuration. Loaded before any app dependency.
#
# `:atlas`     — kernel (event log, projection, indexer, watcher, GC).
# `:atlas_web` — Phoenix LiveView app that consumes the kernel.

import Config

# --- :atlas (kernel) ---

config :atlas,
  ecto_repos: [Atlas.Repo],
  # Subdirectory under :atlas priv_dir for runtime state: store chunks, log DB,
  # projection DB. Resolved absolute at runtime so CWD does not matter.
  data_dir: "data"

config :atlas, Atlas.Repo,
  database: "data/projection.db",
  pool_size: 5,
  journal_mode: :wal,
  cache_size: -64_000,
  temp_store: :memory,
  show_sensitive_data_on_connection_error: false

# --- :atlas_web (Phoenix) ---

config :atlas_web,
  generators: [timestamp_type: :utc_datetime]

config :atlas_web, AtlasWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: AtlasWeb.ErrorHTML, json: AtlasWeb.ErrorJSON],
    layout: false
  ],
  # Atlas.PubSub is supervised by Atlas.Application; AtlasWeb just broadcasts
  # into it and subscribes from LiveViews.
  pubsub_server: Atlas.PubSub,
  live_view: [signing_salt: "bqZJaBJQGZGQqoOrKQEIi6mOBh09lX1Q"]

# Asset build pipelines (Phoenix defaults)
config :esbuild,
  version: "0.25.4",
  atlas_web: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../apps/atlas_web/assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

config :tailwind,
  version: "4.1.12",
  atlas_web: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("../apps/atlas_web", __DIR__)
  ]

# --- logger / shared ---

config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id, :module]

config :phoenix, :json_library, Jason

# Environment-specific overrides.
import_config "#{config_env()}.exs"
