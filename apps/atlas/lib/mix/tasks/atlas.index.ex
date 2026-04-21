defmodule Mix.Tasks.Atlas.Index do
  @shortdoc "Walk, chunk, and log a directory tree"
  @moduledoc """
  Index a directory into Atlas.

      mix atlas.index <path>
  """

  use Mix.Task

  @impl true
  def run([path]) do
    Mix.Task.run("app.start")
    Atlas.CLI.main(["index", path])
  end

  def run(_) do
    Mix.shell().error("Usage: mix atlas.index <path>")
    exit({:shutdown, 1})
  end
end
