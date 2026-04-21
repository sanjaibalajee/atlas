defmodule Atlas.Umbrella.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/sanjaibalajee/atlas"

  def project do
    [
      apps_path: "apps",
      version: @version,
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      listeners: [Phoenix.CodeReloader],
      name: "Atlas",
      description: "A content-addressed, event-sourced file system.",
      source_url: @source_url,
      docs: docs()
    ]
  end

  defp deps do
    [
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:stream_data, "~> 1.1", only: [:dev, :test]}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "cmd --app atlas mix ecto.setup"],
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
        Infrastructure: ~r/Atlas\.(Native|Repo|CLI|Application|Schemas)/,
        Web: ~r/AtlasWeb/
      ]
    ]
  end
end
