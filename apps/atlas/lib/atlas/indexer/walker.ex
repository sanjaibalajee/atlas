defmodule Atlas.Indexer.Walker do
  @moduledoc """
  Lazy recursive directory walker.

  `stream/1` returns a `Stream` of absolute paths for every regular file
  beneath the given root. Symlinks and special files are skipped. Errors
  on individual entries are logged and skipped rather than halting the
  whole walk.

  Pass an `Atlas.Indexer.Ignore` matcher via `stream/2` to prune
  subtrees that match the location's ignore patterns. Pruning happens
  before `ls`/`stat` on children — ignored `node_modules/` directories
  cost nothing past one stat + one pattern match.
  """

  require Logger

  alias Atlas.Indexer.Ignore

  @type opts :: [ignore: Ignore.compiled()]

  @spec stream(Path.t()) :: Enumerable.t()
  def stream(root), do: stream(root, [])

  @spec stream(Path.t(), opts()) :: Enumerable.t()
  def stream(root, opts) do
    root = Path.expand(root)
    ignore = Keyword.get(opts, :ignore, %Ignore{})

    Stream.resource(
      fn -> [{root, :root}] end,
      &step(&1, root, ignore),
      fn _ -> :ok end
    )
  end

  defp step([], _root, _ignore), do: {:halt, []}

  defp step([{path, rel} | rest], root, ignore) do
    cond do
      # Hard invariant: never walk into Atlas's own state directory. Without
      # this, pointing Atlas at `$HOME` indexes its own `priv/data/store/`
      # CAS, creating a self-indexing feedback loop that the user can't
      # opt out of via ignore patterns.
      Atlas.internal_path?(path) ->
        step(rest, root, ignore)

      rel != :root and Ignore.match?(ignore, rel) ->
        step(rest, root, ignore)

      true ->
        case File.stat(path) do
          {:ok, %File.Stat{type: :regular}} ->
            {[path], rest}

          {:ok, %File.Stat{type: :directory}} ->
            children = list_children(path, root)
            step(children ++ rest, root, ignore)

          {:ok, _other} ->
            step(rest, root, ignore)

          {:error, reason} ->
            Logger.debug("walker: skip #{path}: #{inspect(reason)}")
            step(rest, root, ignore)
        end
    end
  end

  defp list_children(dir, root) do
    case File.ls(dir) do
      {:ok, names} ->
        Enum.map(names, fn name ->
          full = Path.join(dir, name)
          {full, relative_from(root, full)}
        end)

      {:error, reason} ->
        Logger.debug("walker: ls #{dir} failed: #{inspect(reason)}")
        []
    end
  end

  defp relative_from(root, full) do
    case Path.relative_to(full, root) do
      ^full -> full
      rel -> rel
    end
  end
end
