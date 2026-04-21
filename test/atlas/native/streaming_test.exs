defmodule Atlas.Native.StreamingTest do
  @moduledoc """
  Tests for `Atlas.Native.chunk_and_store_file/2` (M1.3).

  Verifies that the streaming NIF produces the same chunks as the
  whole-file variant, writes chunk files to the right CAS path, and is
  idempotent across repeated runs.
  """

  use ExUnit.Case, async: true

  @moduletag :nif

  alias Atlas.Domain.Chunk, as: ChunkDomain

  setup do
    base = Path.join(System.tmp_dir!(), "atlas_stream_#{System.unique_integer([:positive])}")
    file_path = Path.join(base, "input.bin")
    store_root = Path.join(base, "store")

    File.mkdir_p!(base)
    File.mkdir_p!(store_root)

    on_exit(fn -> File.rm_rf(base) end)

    {:ok, path: file_path, store: store_root, base: base}
  end

  defp chunk_path(store_root, hash) do
    hex = Atlas.Domain.Hash.to_hex(hash)
    <<shard::binary-size(2), rest::binary>> = hex
    Path.join([store_root, shard, rest])
  end

  test "writes every chunk to the correct CAS location", %{path: path, store: store} do
    data = :crypto.strong_rand_bytes(700_000)
    File.write!(path, data)

    assert {:ok, chunks} = Atlas.Native.chunk_and_store_file(path, store)
    assert length(chunks) >= 2

    for c <- chunks do
      disk_path = chunk_path(store, c.hash)
      assert File.exists?(disk_path), "expected chunk file at #{disk_path}"
      assert File.read!(disk_path) |> byte_size() == c.length
    end
  end

  test "stored chunk bytes hash to the reported chunk hash", %{path: path, store: store} do
    data = :crypto.strong_rand_bytes(300_000)
    File.write!(path, data)

    {:ok, chunks} = Atlas.Native.chunk_and_store_file(path, store)

    for c <- chunks do
      on_disk = File.read!(chunk_path(store, c.hash))
      assert Atlas.Native.hash_bytes(on_disk) == c.hash
    end
  end

  test "chunks sum to the file size", %{path: path, store: store} do
    data = :crypto.strong_rand_bytes(1_500_000)
    File.write!(path, data)

    {:ok, chunks} = Atlas.Native.chunk_and_store_file(path, store)
    assert ChunkDomain.total_size(chunks) == byte_size(data)
  end

  test "same content produces the same chunks as the whole-file chunker",
       %{path: path, store: store} do
    data = :crypto.strong_rand_bytes(500_000)
    File.write!(path, data)

    {:ok, streaming} = Atlas.Native.chunk_and_store_file(path, store)
    {:ok, whole_file} = Atlas.Native.chunk_file(path)

    strip = fn list ->
      Enum.map(list, fn c -> {c.offset, c.length, c.hash} end)
    end

    assert strip.(streaming) == strip.(whole_file)
  end

  test "idempotent: second call is a no-op on disk", %{path: path, store: store} do
    data = :crypto.strong_rand_bytes(400_000)
    File.write!(path, data)

    {:ok, chunks} = Atlas.Native.chunk_and_store_file(path, store)
    mtimes_before =
      chunks
      |> Enum.map(&chunk_path(store, &1.hash))
      |> Enum.map(&File.stat!/1)
      |> Enum.map(& &1.mtime)

    Process.sleep(1100)
    {:ok, _chunks2} = Atlas.Native.chunk_and_store_file(path, store)

    mtimes_after =
      chunks
      |> Enum.map(&chunk_path(store, &1.hash))
      |> Enum.map(&File.stat!/1)
      |> Enum.map(& &1.mtime)

    assert mtimes_before == mtimes_after, "idempotent write should not rewrite existing chunk files"
  end

  test "errors on missing file", %{store: store} do
    assert {:error, _reason} =
             Atlas.Native.chunk_and_store_file("/does/not/exist", store)
  end
end
