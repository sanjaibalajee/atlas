defmodule Mix.Tasks.Atlas.Unwatch do
  @shortdoc "Stop watching a location"
  @moduledoc """
      mix atlas.unwatch <path>
  """

  use Mix.Task

  @impl true
  def run([path]) do
    Mix.Task.run("app.start")
    Atlas.CLI.main(["unwatch", path])
  end

  def run(_) do
    Mix.shell().error("Usage: mix atlas.unwatch <path>")
    exit({:shutdown, 1})
  end
end
