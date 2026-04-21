defmodule Atlas.MixProject do
  use Mix.Project

  @version "0.1.0"

  def project do
    [
      app: :atlas,
      version: `@version`,
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      escript: escript(),
      aliases: aliases(),
      cli: cli(),
      dialyzer: dialyzer(),
      test_coverage: [summary: [threshold: 75]]
    ]
  end

  def cli do
    [preferred_envs: [credo: :test, dialyzer: :test]]
  end

  def application do
    [
      extra_applications: [:logger, :crypto, :runtime_tools],
      mod: {Atlas.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # Native code (BLAKE3, FastCDC)
      {:rustler, "~> 0.34"},

      # Persistence (projections only — the event log is the truth)
      {:ecto_sql, "~> 3.12"},
      {:ecto_sqlite3, "~> 0.17"},

      # Serialization
      {:jason, "~> 1.4"},
      {:msgpax, "~> 2.4"},

      # Filesystem watching (FSEvents/inotify)
      {:file_system, "~> 1.0"},

      # Pub/sub fan-out to LiveView subscribers
      {:phoenix_pubsub, "~> 2.1"}
    ]
  end

  defp escript do
    [
      main_module: Atlas.CLI,
      name: "atlas",
      app: nil
    ]
  end

  defp aliases do
    [
      "ecto.setup": ["ecto.create", "ecto.migrate"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"]
    ]
  end

  defp dialyzer do
    [
      plt_add_apps: [:mix, :ex_unit],
      plt_file: {:no_warn, "../../priv/plts/dialyzer.plt"},
      flags: [:error_handling, :unknown, :underspecs]
    ]
  end
end
