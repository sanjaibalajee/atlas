defmodule Atlas.GC do
  @moduledoc """
  Reclaim orphan chunks — content-addressed objects that no live file
  references.

  After a `FileModified` or `FileDeleted` event, the projector recomputes
  `chunks.ref_count`. A chunk whose count lands at 0 is an orphan: its
  bytes still sit in `priv/data/store/<shard>/<rest>` but no `file_chunks`
  row points at it.

  `sweep/1`:

    1. selects chunks with `ref_count = 0`
    2. deletes the corresponding file from the CAS
    3. deletes the chunk row

  Everything happens outside a single transaction — we'd rather have a
  little leftover file (which the NEXT sweep will catch) than hold a DB
  lock across slow filesystem operations.

      Atlas.GC.sweep()
      #=> %{scanned: 12, removed: 12, bytes_reclaimed: 2_416_789}

      Atlas.GC.sweep(dry_run: true)
      #=> %{scanned: 12, removed: 0, bytes_reclaimed: 2_416_789}
  """

  import Ecto.Query
  require Logger

  alias Atlas.Repo
  alias Atlas.Schemas.Chunk

  @type result :: %{
          scanned: non_neg_integer(),
          removed: non_neg_integer(),
          bytes_reclaimed: non_neg_integer()
        }

  @spec sweep(keyword()) :: result()
  def sweep(opts \\ []) do
    dry_run? = Keyword.get(opts, :dry_run, false)

    orphans = Repo.all(from c in Chunk, where: c.ref_count == 0)
    bytes = Enum.reduce(orphans, 0, fn c, acc -> acc + c.length end)

    removed =
      if dry_run? do
        0
      else
        Enum.reduce(orphans, 0, fn chunk, acc ->
          if remove_chunk(chunk) == :ok, do: acc + 1, else: acc
        end)
      end

    if !dry_run? and removed > 0 do
      Logger.info("gc: removed #{removed} orphan chunk(s), reclaimed #{bytes} bytes")
    end

    %{scanned: length(orphans), removed: removed, bytes_reclaimed: bytes}
  end

  @doc "Filesystem path for a chunk in the local CAS."
  @spec chunk_path(binary()) :: Path.t()
  def chunk_path(hash) do
    hex = Atlas.Domain.Hash.to_hex(hash)
    <<shard::binary-size(2), rest::binary>> = hex
    Path.join([Atlas.store_dir(), shard, rest])
  end

  defp remove_chunk(%Chunk{hash: hash} = chunk) do
    # Delete from the CAS first. If the file was never written (crash
    # between event and store), skip silently — we still want to drop the
    # projection row.
    path = chunk_path(hash)
    _ = File.rm(path)

    Repo.delete!(chunk)
    :ok
  rescue
    e ->
      Logger.warning("gc: failed to remove chunk #{Atlas.Domain.Hash.short(hash)}: #{inspect(e)}")
      :error
  end
end
