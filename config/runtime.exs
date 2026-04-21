import Config

# Runtime (post-compile) config. Used when Atlas starts in prod or
# when launched via the escript.

if config_env() == :prod do
  data_dir =
    System.get_env("ATLAS_DATA_DIR") ||
      Path.join(System.user_home!(), ".atlas")

  config :atlas, data_dir: data_dir

  config :atlas, Atlas.Repo,
    database: Path.join(data_dir, "projection.db"),
    pool_size: String.to_integer(System.get_env("ATLAS_POOL_SIZE", "10"))
end
