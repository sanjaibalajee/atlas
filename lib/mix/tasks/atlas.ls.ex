defmodule Mix.Tasks.Atlas.Ls do
  @shortdoc "List indexed files"
  @moduledoc "List all currently-indexed (non-deleted) files."

  use Mix.Task

  @impl true
  def run(_args) do
    Mix.Task.run("app.start")
    Atlas.CLI.main(["ls"])
  end
end
