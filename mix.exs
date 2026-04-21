defmodule Atlas.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/sanjaibalajee/atlas"

  def project do
    [
      app: :atlas,
      version: @version,
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      escript: escript(),
      aliases: aliases(),
      name: "Atlas",
      description: "A content-addressed, event-sourced file system.",
      source_url: @source_url,
      docs: docs(),
      dialyzer: dialyzer(),
      test_coverage: [summary: [threshold: 75]]
    ]
  end

  # Rustler 0.30+ drove crate configuration into `use Rustler` itself — there
  # is no longer a `:rustler` mix compiler to register here. See
  # `lib/atlas/native.ex`.

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

      # Filesystem watching (FSEvents/inotify) — M1.6
      {:file_system, "~> 1.0"},

      # Tooling
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:stream_data, "~> 1.1", only: [:dev, :test]}
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
      setup: ["deps.get", "ecto.setup"],
      "ecto.setup": ["ecto.create", "ecto.migrate"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"],
      check: ["format --check-formatted", "credo --strict", "dialyzer", "test"]
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md"],
      groups_for_modules: [
        Domain: ~r/Atlas\.Domain/,
        Store: ~r/Atlas\.Store/,
        Log: ~r/Atlas\.Log/,
        Projection: ~r/Atlas\.Projection/,
        Indexer: ~r/Atlas\.Indexer/,
        Infrastructure: ~r/Atlas\.(Native|Repo|CLI|Application|Schemas)/
      ]
    ]
  end

  defp dialyzer do
    [
      plt_add_apps: [:mix, :ex_unit],
      plt_file: {:no_warn, "priv/plts/dialyzer.plt"},
      flags: [:error_handling, :unknown, :underspecs]
    ]
  end
end
