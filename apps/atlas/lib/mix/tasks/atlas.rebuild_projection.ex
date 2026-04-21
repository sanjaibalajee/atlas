defmodule Mix.Tasks.Atlas.RebuildProjection do
  @shortdoc "Drop the projection DB and rebuild it from the event log"
  @moduledoc """
  Drops every projection table and replays the event log from the
  beginning. Useful to prove that the log is the sole source of truth.

      mix atlas.rebuild_projection
  """

  use Mix.Task

  @impl true
  def run(_args) do
    Mix.Task.run("app.start")
    Atlas.CLI.main(["rebuild-projection"])
  end
end
