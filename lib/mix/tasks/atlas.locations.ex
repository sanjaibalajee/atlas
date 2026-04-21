defmodule Mix.Tasks.Atlas.Locations do
  @shortdoc "List currently watched locations"
  @moduledoc """
      mix atlas.locations
  """

  use Mix.Task

  @impl true
  def run(_args) do
    Mix.Task.run("app.start")
    Atlas.CLI.main(["locations"])
  end
end
