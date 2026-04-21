defmodule Mix.Tasks.Atlas.Watch do
  @shortdoc "Add a location and watch it for live changes"
  @moduledoc """
      mix atlas.watch <path>

  Appends a `LocationAdded` event, runs an initial scan, starts a
  filesystem watcher, and then blocks, printing every event to stdout.
  Ctrl-C to stop.
  """

  use Mix.Task

  @impl true
  def run([path]) do
    Mix.Task.run("app.start")
    Atlas.CLI.main(["watch", path])
  end

  def run(_) do
    Mix.shell().error("Usage: mix atlas.watch <path>")
    exit({:shutdown, 1})
  end
end
