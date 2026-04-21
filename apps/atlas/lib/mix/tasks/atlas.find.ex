defmodule Mix.Tasks.Atlas.Find do
  @shortdoc "Find indexed files whose path matches a substring"
  @moduledoc """
      mix atlas.find <term>
  """

  use Mix.Task

  @impl true
  def run([term]) do
    Mix.Task.run("app.start")
    Atlas.CLI.main(["find", term])
  end

  def run(_) do
    Mix.shell().error("Usage: mix atlas.find <term>")
    exit({:shutdown, 1})
  end
end
