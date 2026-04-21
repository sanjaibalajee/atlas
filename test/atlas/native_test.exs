defmodule Atlas.NativeTest do
  use ExUnit.Case, async: true

  @moduletag :nif

  alias Atlas.Domain.Chunk

  describe "hash_bytes/1" do
    test "returns 32 bytes" do
      assert byte_size(Atlas.Native.hash_bytes("hello")) == 32
    end

    test "is deterministic" do
      assert Atlas.Native.hash_bytes("abc") == Atlas.Native.hash_bytes("abc")
    end

    test "differs on different inputs" do
      refute Atlas.Native.hash_bytes("a") == Atlas.Native.hash_bytes("b")
    end
  end

  describe "chunk_bytes/1" do
    test "returns one chunk for small input" do
      assert [%Chunk{offset: 0, length: 5, hash: h}] = Atlas.Native.chunk_bytes("hello")
      assert byte_size(h) == 32
    end

    test "chunk lengths sum to the input size" do
      data = :crypto.strong_rand_bytes(1_000_000)
      chunks = Atlas.Native.chunk_bytes(data)
      assert Chunk.total_size(chunks) == byte_size(data)
    end

    test "chunks are contiguous" do
      data = :crypto.strong_rand_bytes(500_000)
      chunks = Atlas.Native.chunk_bytes(data)

      Enum.reduce(chunks, 0, fn c, expected_offset ->
        assert c.offset == expected_offset
        c.offset + c.length
      end)
    end

    test "is deterministic" do
      data = :crypto.strong_rand_bytes(200_000)
      assert Atlas.Native.chunk_bytes(data) == Atlas.Native.chunk_bytes(data)
    end
  end

  describe "hash_file/1 and chunk_file/1" do
    setup do
      path = Path.join(System.tmp_dir!(), "atlas_nif_#{System.unique_integer([:positive])}.bin")
      data = :crypto.strong_rand_bytes(150_000)
      File.write!(path, data)
      on_exit(fn -> File.rm(path) end)
      {:ok, path: path, data: data}
    end

    test "hash_file matches hash_bytes on the same content", %{path: path, data: data} do
      assert {:ok, h} = Atlas.Native.hash_file(path)
      assert h == Atlas.Native.hash_bytes(data)
    end

    test "chunk_file matches chunk_bytes on the same content", %{path: path, data: data} do
      assert {:ok, from_file} = Atlas.Native.chunk_file(path)
      assert from_file == Atlas.Native.chunk_bytes(data)
    end

    test "chunk_file errors on missing file" do
      assert {:error, _reason} = Atlas.Native.chunk_file("/definitely/does/not/exist")
    end
  end
end
