defmodule Atlas.Indexer do
  @moduledoc """
  Walk a directory, chunk + hash each file, store chunks, emit events.

  Phase 1 adds **incrementality** (M1.2) and **streaming chunking** (M1.3).

  Pipeline per file:

      stat                                  — size + mtime
      look up current projection row        — new / modified / unchanged?
      if unchanged:  emit no event, done.
      else:          chunk_and_store_file    — one pass: stream → chunk → store
                     append FileIndexed/FileModified event

  Caveats (addressed in later milestones):

    * mtime-only change detection misses sub-second rewrites.
    * Files that have *disappeared* since the last scan are not detected —
      that's what the filesystem watcher (M1.6) is for.
  """

  alias Atlas.Domain.{Chunk, Event}
  alias Atlas.Schemas.File, as: FileRow
  require Logger

  @type result :: %{
          new: non_neg_integer(),
          modified: non_neg_integer(),
          unchanged: non_neg_integer(),
          bytes: non_neg_integer(),
          errors: non_neg_integer()
        }

  @spec index(Path.t()) :: {:ok, result()}
  def index(root) do
    root = Path.expand(root)
    Logger.info("indexer: walking #{root}")

    result =
      root
      |> Atlas.Indexer.Walker.stream()
      |> Enum.reduce(init_result(), fn path, acc -> tally(acc, index_file(path)) end)

    Logger.info("indexer: done — #{inspect(result)}")
    {:ok, result}
  end

  @doc """
  Index one file by absolute path. Public so the filesystem watcher (M1.6)
  can drive per-change indexing. Returns one of:

      {:new       | :modified | :unchanged, size}
      {:error, reason, path}
  """
  @spec index_file(Path.t()) ::
          {:new, non_neg_integer()}
          | {:modified, non_neg_integer()}
          | {:unchanged, non_neg_integer()}
          | {:error, term(), Path.t()}
  def index_file(path) do
    case File.stat(path, time: :posix) do
      {:ok, stat} ->
        mtime_us = stat.mtime * 1_000_000
        classify_and_index(path, stat, mtime_us, lookup_previous(path))

      {:error, reason} ->
        {:error, reason, path}
    end
  end

  # First-time index — emit FileIndexed.
  defp classify_and_index(path, stat, mtime_us, nil) do
    do_index(path, stat, mtime_us, :new)
  end

  # Stat unchanged — no event, no work.
  defp classify_and_index(_path, stat, mtime_us, %FileRow{size: s, mtime_us: m})
       when s == stat.size and m == mtime_us do
    {:unchanged, stat.size}
  end

  # Stat differs — re-chunk and emit FileModified.
  defp classify_and_index(path, stat, mtime_us, %FileRow{}) do
    do_index(path, stat, mtime_us, :modified)
  end

  defp do_index(path, stat, mtime_us, kind) do
    case Atlas.Native.chunk_and_store_file(path, Atlas.store_dir()) do
      {:ok, chunks} ->
        event = build_event(path, stat, mtime_us, chunks, kind)
        {:ok, _seq} = Atlas.Log.append(event)
        {kind, stat.size}

      {:error, reason} ->
        {:error, reason, path}
    end
  end

  defp build_event(path, stat, mtime_us, chunks, :new) do
    %Event.FileIndexed{
      v: 1,
      at: Event.now_us(),
      path: path,
      size: stat.size,
      mtime_us: mtime_us,
      root_hash: Chunk.root_hash(chunks),
      chunks: chunks
    }
  end

  defp build_event(path, stat, mtime_us, chunks, :modified) do
    %Event.FileModified{
      v: 1,
      at: Event.now_us(),
      path: path,
      size: stat.size,
      mtime_us: mtime_us,
      root_hash: Chunk.root_hash(chunks),
      chunks: chunks
    }
  end

  # Projection lookup with a rescue — test setup may not have the table.
  defp lookup_previous(path) do
    Atlas.Repo.get_by(FileRow, path: path)
  rescue
    _ -> nil
  end

  # --- Tally ---

  defp init_result,
    do: %{new: 0, modified: 0, unchanged: 0, bytes: 0, errors: 0}

  defp tally(acc, {:new, size}),
    do: %{acc | new: acc.new + 1, bytes: acc.bytes + size}

  defp tally(acc, {:modified, size}),
    do: %{acc | modified: acc.modified + 1, bytes: acc.bytes + size}

  defp tally(acc, {:unchanged, size}),
    do: %{acc | unchanged: acc.unchanged + 1, bytes: acc.bytes + size}

  defp tally(acc, {:error, reason, path}) do
    Logger.warning("indexer: skip #{path}: #{inspect(reason)}")
    %{acc | errors: acc.errors + 1}
  end
end
