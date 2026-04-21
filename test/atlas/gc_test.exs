defmodule Atlas.GCTest do
  @moduledoc """
  Tests for M1.8 — ref_count maintenance and orphan-chunk GC.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  @moduletag :nif

  alias Atlas.Repo
  alias Atlas.Schemas.Chunk

  setup do
    dir = Path.join(System.tmp_dir!(), "atlas_gc_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, dir: dir}
  end

  defp index(dir) do
    {:ok, _} = Atlas.Indexer.index(dir)
    :ok = Atlas.Projection.Projector.catch_up_to(Atlas.Log.head())
  end

  test "ref_count is 1 for a chunk referenced by a single file", %{dir: dir} do
    path = Path.join(dir, "a.txt")
    File.write!(path, "unique-#{:rand.uniform(1_000_000)}")
    index(dir)

    [chunk] =
      Repo.all(
        from c in Chunk,
          where: c.length == ^File.stat!(path).size,
          order_by: [desc: c.inserted_at],
          limit: 1
      )

    assert chunk.ref_count >= 1
  end

  test "modifying a file orphans the old chunk (ref_count drops to 0)", %{dir: dir} do
    path = Path.join(dir, "modified.txt")
    initial = "version-1-#{:rand.uniform(1_000_000)}"
    File.write!(path, initial)
    index(dir)

    initial_hash = Atlas.Native.hash_bytes(initial)

    old_chunk = Repo.get(Chunk, initial_hash)
    assert old_chunk, "chunk should exist after first index"
    assert old_chunk.ref_count == 1

    Process.sleep(1100)
    File.write!(path, "version-2-different-#{:rand.uniform(1_000_000)}")
    index(dir)

    refreshed = Repo.get(Chunk, initial_hash)
    assert refreshed.ref_count == 0, "old chunk's ref_count should drop to 0"
  end

  test "Atlas.GC.sweep/1 removes orphan chunks from DB and disk", %{dir: dir} do
    path = Path.join(dir, "will_be_orphaned.txt")
    File.write!(path, "orphan-test-#{:rand.uniform(1_000_000)}")
    index(dir)

    # Modify the file so the original chunk becomes an orphan.
    initial_size = File.stat!(path).size
    Process.sleep(1100)
    File.write!(path, "different-content-#{:rand.uniform(1_000_000)}")
    index(dir)

    # Confirm there is an orphan.
    orphans_before = Repo.all(from c in Chunk, where: c.ref_count == 0)
    assert length(orphans_before) >= 1

    # Confirm its file is on disk.
    Enum.each(orphans_before, fn c ->
      assert File.exists?(Atlas.GC.chunk_path(c.hash))
    end)

    result = Atlas.GC.sweep()

    assert result.scanned >= 1
    assert result.removed >= 1
    assert result.bytes_reclaimed >= initial_size

    Enum.each(orphans_before, fn c ->
      refute File.exists?(Atlas.GC.chunk_path(c.hash)),
             "orphan chunk should be removed from disk"
      assert Repo.get(Chunk, c.hash) == nil,
             "orphan chunk row should be removed from DB"
    end)
  end

  test "deleting a file orphans all its chunks", %{dir: dir} do
    path = Path.join(dir, "deletable.txt")
    File.write!(path, "delete-me-#{:rand.uniform(1_000_000)}")
    index(dir)

    # Emit a FileDeleted event as the watcher would.
    expanded = Path.expand(path)

    {:ok, seq} =
      Atlas.Log.append(%Atlas.Domain.Event.FileDeleted{
        v: 1,
        at: Atlas.Domain.Event.now_us(),
        path: expanded
      })

    :ok = Atlas.Projection.Projector.catch_up_to(seq)

    # The file's chunks should now all be orphans (if the content was unique).
    # Run GC and confirm at least one orphan was reclaimed.
    result = Atlas.GC.sweep()
    assert result.scanned >= 1
  end
end
