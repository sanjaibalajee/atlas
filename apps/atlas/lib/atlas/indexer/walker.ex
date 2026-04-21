defmodule Atlas.Indexer.Walker do
  @moduledoc """
  Lazy recursive directory walker.

  `stream/1` returns a `Stream` of absolute paths for every regular file
  beneath the given root. Symlinks and special files are skipped. Errors
  on individual entries are logged and skipped rather than halting the
  whole walk.
  """

  require Logger

  @spec stream(Path.t()) :: Enumerable.t()
  def stream(root) do
    root = Path.expand(root)

    Stream.resource(
      fn -> [root] end,
      &step/1,
      fn _ -> :ok end
    )
  end

  defp step([]), do: {:halt, []}

  defp step([path | rest]) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular}} ->
        {[path], rest}

      {:ok, %File.Stat{type: :directory}} ->
        children = list_children(path)
        step(children ++ rest)

      {:ok, _other} ->
        step(rest)

      {:error, reason} ->
        Logger.debug("walker: skip #{path}: #{inspect(reason)}")
        step(rest)
    end
  end

  defp list_children(dir) do
    case File.ls(dir) do
      {:ok, names} ->
        Enum.map(names, &Path.join(dir, &1))

      {:error, reason} ->
        Logger.debug("walker: ls #{dir} failed: #{inspect(reason)}")
        []
    end
  end
end
