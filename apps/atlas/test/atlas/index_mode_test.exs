defmodule Atlas.IndexModeTest do
  @moduledoc """
  Integration tests for the shallow-by-default index mode introduced in
  M2.7-prep. Ensures shallow locations don't write to the CAS, content
  locations do, and `set_mode/2` flips behaviour without dropping files
  already indexed under the previous mode.
  """

  use ExUnit.Case, async: false

  @moduletag :nif

  alias Atlas.Library
  alias Atlas.Locations

  import Ecto.Query

  setup do
    dir = Path.join(System.tmp_dir!(), "atlas_mode_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "a.txt"), String.duplicate("a", 512))
    File.write!(Path.join(dir, "b.txt"), String.duplicate("b", 1024))

    on_exit(fn ->
      _ = Locations.remove(dir)
      File.rm_rf(dir)
    end)

    {:ok, dir: dir}
  end

  describe "shallow mode (default)" do
    test "writes no Chunk rows and no file_chunks", %{dir: dir} do
      {:ok, _} = Locations.add(dir)
      location = Locations.get(dir)

      assert location.index_mode == "shallow"

      # Two files indexed, but neither produced a chunk row.
      %{rows: rows} = Library.list_files(location.id, limit: 10)
      assert length(rows) == 2

      file_ids = Enum.map(rows, & &1.id)

      chunk_row_count =
        Atlas.Repo.aggregate(
          from(fc in Atlas.Schemas.FileChunk, where: fc.file_id in ^file_ids),
          :count,
          :ordinal
        )

      assert chunk_row_count == 0
    end

    test "each file still has a non-nil 32-byte root_hash", %{dir: dir} do
      {:ok, _} = Locations.add(dir)
      location = Locations.get(dir)
      %{rows: rows} = Library.list_files(location.id, limit: 10)

      for file <- rows do
        assert byte_size(file.root_hash) == 32
      end
    end
  end

  describe "content mode (opt-in)" do
    test "writes chunks and file_chunks rows", %{dir: dir} do
      {:ok, _} = Locations.add(dir, mode: :content)
      location = Locations.get(dir)

      assert location.index_mode == "content"

      %{rows: rows} = Library.list_files(location.id, limit: 10)
      file_ids = Enum.map(rows, & &1.id)

      chunk_row_count =
        Atlas.Repo.aggregate(
          from(fc in Atlas.Schemas.FileChunk, where: fc.file_id in ^file_ids),
          :count,
          :ordinal
        )

      assert chunk_row_count >= 2,
             "expected at least one file_chunks row per file in content mode"
    end
  end

  describe "set_mode/2" do
    test "switching to content and rescanning produces chunks", %{dir: dir} do
      {:ok, _} = Locations.add(dir)
      location = Locations.get(dir)
      assert location.index_mode == "shallow"

      :ok = Locations.set_mode(dir, :content)
      reloaded = Locations.get(dir)
      assert reloaded.index_mode == "content"

      # Mode flip alone doesn't re-hash existing files (mtime unchanged).
      # A rescan with the new mode does: we write fresh content and
      # re-scan to force modify events.
      Process.sleep(1100)
      File.write!(Path.join(dir, "a.txt"), String.duplicate("A", 4096))

      {:ok, _} = Locations.scan(dir)

      %{rows: rows} = Library.list_files(reloaded.id, limit: 10)
      file_ids = Enum.map(rows, & &1.id)

      chunk_row_count =
        Atlas.Repo.aggregate(
          from(fc in Atlas.Schemas.FileChunk, where: fc.file_id in ^file_ids),
          :count,
          :ordinal
        )

      assert chunk_row_count >= 1,
             "expected at least one file_chunks row after content-mode rescan"
    end

    test "returns :not_found for unknown or tombstoned locations" do
      assert {:error, :not_found} = Locations.set_mode("/nowhere/real", :content)
    end
  end

  describe "Locations.add/2 validation" do
    test "rejects invalid mode values", %{dir: dir} do
      assert_raise ArgumentError, fn ->
        Locations.add(dir, mode: :bogus)
      end
    end
  end
end
