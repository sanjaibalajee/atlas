defmodule Mix.Tasks.Atlas.Gc do
  @shortdoc "Reclaim orphan chunks from the object store"
  @moduledoc """
      mix atlas.gc             # actually remove
      mix atlas.gc --dry-run   # report only
  """

  use Mix.Task

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _, _} = OptionParser.parse(args, switches: [dry_run: :boolean])

    Atlas.CLI.main(if opts[:dry_run], do: ["gc", "--dry-run"], else: ["gc"])
  end
end
