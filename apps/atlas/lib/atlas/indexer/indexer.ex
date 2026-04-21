defmodule Atlas.Indexer do
  @moduledoc """
  Walk a directory, hash each file, emit events.

  Two indexing modes:

    * `:shallow` (default) — compute a sampled BLAKE3 digest from the
      file header / interior samples / tail + size. No chunking, no CAS
      writes. Cheapest, good for "I just want Atlas to see my files."

    * `:content` — FastCDC-chunk the file and write each chunk into the
      local CAS. Enables chunk-level dedup, P2P sync (Phase 4), and
      content-addressed sidecars for extensions (Phase 3). Costs roughly
      1× the source size in on-disk chunks.

  Pipeline per file (both modes):

      stat                                   — size + mtime
      look up current projection row         — new / modified / unchanged?
      if unchanged:  emit no event.
      else:          mode-specific hashing   — shallow sample or full chunks
                     append FileIndexed / FileModified event
  """

  alias Atlas.Domain.{Chunk, Event}
  alias Atlas.Indexer.SampledHash
  alias Atlas.Schemas.File, as: FileRow
  require Logger

  @type result :: %{
          new: non_neg_integer(),
          modified: non_neg_integer(),
          unchanged: non_neg_integer(),
          bytes: non_neg_integer(),
          errors: non_neg_integer()
        }

  @type mode :: :shallow | :content

  @type index_opts :: [
          ignore: [String.t()] | Atlas.Indexer.Ignore.compiled(),
          mode: mode()
        ]

  @spec index(Path.t(), index_opts()) :: {:ok, result()}
  def index(root, opts \\ []) do
    root = Path.expand(root)
    ignore = compile_ignore(Keyword.get(opts, :ignore, []))
    mode = Keyword.get(opts, :mode, :shallow)
    Logger.info("indexer: walking #{root} (mode: #{mode})")

    result =
      root
      |> Atlas.Indexer.Walker.stream(ignore: ignore)
      |> Enum.reduce(init_result(), fn path, acc -> tally(acc, index_file(path, mode)) end)

    Logger.info("indexer: done — #{inspect(result)}")
    {:ok, result}
  end

  defp compile_ignore(%Atlas.Indexer.Ignore{} = m), do: m
  defp compile_ignore(list) when is_list(list), do: Atlas.Indexer.Ignore.compile(list)

  @doc """
  Index one file. `mode` defaults to `:shallow` when omitted — same as
  new locations. Returns one of:

      {:new       | :modified | :unchanged, size}
      {:error, reason, path}
  """
  @spec index_file(Path.t(), mode()) ::
          {:new, non_neg_integer()}
          | {:modified, non_neg_integer()}
          | {:unchanged, non_neg_integer()}
          | {:error, term(), Path.t()}
  def index_file(path, mode \\ :shallow) do
    case File.stat(path, time: :posix) do
      {:ok, stat} ->
        mtime_us = stat.mtime * 1_000_000
        classify_and_index(path, stat, mtime_us, mode, lookup_previous(path))

      {:error, reason} ->
        {:error, reason, path}
    end
  end

  # First-time index — emit FileIndexed.
  defp classify_and_index(path, stat, mtime_us, mode, nil) do
    do_index(path, stat, mtime_us, mode, :new)
  end

  # Stat unchanged — no event, no work.
  defp classify_and_index(_path, stat, mtime_us, _mode, %FileRow{size: s, mtime_us: m})
       when s == stat.size and m == mtime_us do
    {:unchanged, stat.size}
  end

  # Stat differs — re-hash (or re-chunk) and emit FileModified.
  defp classify_and_index(path, stat, mtime_us, mode, %FileRow{}) do
    do_index(path, stat, mtime_us, mode, :modified)
  end

  defp do_index(path, stat, mtime_us, :content, kind) do
    case Atlas.Native.chunk_and_store_file(path, Atlas.store_dir()) do
      {:ok, chunks} ->
        root = Chunk.root_hash(chunks)
        event = build_event(path, stat, mtime_us, root, chunks, kind)
        {:ok, _seq} = Atlas.Log.append(event)
        {kind, stat.size}

      {:error, reason} ->
        {:error, reason, path}
    end
  end

  defp do_index(path, stat, mtime_us, :shallow, kind) do
    case SampledHash.hash_file(path, stat.size) do
      {:ok, root} ->
        event = build_event(path, stat, mtime_us, root, [], kind)
        {:ok, _seq} = Atlas.Log.append(event)
        {kind, stat.size}

      {:error, reason} ->
        {:error, reason, path}
    end
  end

  defp build_event(path, stat, mtime_us, root_hash, chunks, :new) do
    %Event.FileIndexed{
      v: 1,
      at: Event.now_us(),
      path: path,
      size: stat.size,
      mtime_us: mtime_us,
      root_hash: root_hash,
      chunks: chunks
    }
  end

  defp build_event(path, stat, mtime_us, root_hash, chunks, :modified) do
    %Event.FileModified{
      v: 1,
      at: Event.now_us(),
      path: path,
      size: stat.size,
      mtime_us: mtime_us,
      root_hash: root_hash,
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
