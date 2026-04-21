defmodule Atlas.Indexer.SampledHashTest do
  use ExUnit.Case, async: true

  @moduletag :nif

  alias Atlas.Indexer.SampledHash

  setup do
    dir = Path.join(System.tmp_dir!(), "atlas_sample_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, dir: dir}
  end

  describe "small files (< min_sampled_size)" do
    test "hashes the entire file", %{dir: dir} do
      # 1 KB: well below the sampled threshold, so the digest must equal
      # a full-file hash.
      path = Path.join(dir, "small.bin")
      File.write!(path, :crypto.strong_rand_bytes(1024))

      {:ok, full} = Atlas.Native.hash_file(path)
      {:ok, sampled} = SampledHash.hash_file(path, 1024)

      assert sampled == full
    end

    test "deterministic across calls", %{dir: dir} do
      path = Path.join(dir, "stable.bin")
      File.write!(path, :crypto.strong_rand_bytes(1024))

      {:ok, a} = SampledHash.hash_file(path, 1024)
      {:ok, b} = SampledHash.hash_file(path, 1024)
      assert a == b
    end
  end

  describe "large files (>= min_sampled_size)" do
    test "produces a 32-byte digest", %{dir: dir} do
      size = SampledHash.min_sampled_size() + 10_000
      path = Path.join(dir, "big.bin")
      File.write!(path, :crypto.strong_rand_bytes(size))

      {:ok, hash} = SampledHash.hash_file(path, size)
      assert byte_size(hash) == 32
    end

    test "changes when any sampled region changes", %{dir: dir} do
      size = SampledHash.min_sampled_size() + 20_000
      path = Path.join(dir, "mutable.bin")

      original = :crypto.strong_rand_bytes(size)
      File.write!(path, original)
      {:ok, h0} = SampledHash.hash_file(path, size)

      # Flip a byte near the head. Head is part of the sampled region.
      mutated = :binary.replace(original, binary_part(original, 100, 1), <<0xAA>>)
      File.write!(path, mutated)
      {:ok, h1} = SampledHash.hash_file(path, size)

      assert h0 != h1
    end

    test "changes when file size changes even if sampled bytes collide", %{dir: dir} do
      # Same 128 KB content written as two files of different truncations:
      # the size-tag in the digest guarantees they hash differently.
      big = Path.join(dir, "full.bin")
      small = Path.join(dir, "trunc.bin")

      bytes = :crypto.strong_rand_bytes(SampledHash.min_sampled_size() + 50_000)
      File.write!(big, bytes)
      File.write!(small, binary_part(bytes, 0, SampledHash.min_sampled_size() + 1000))

      {:ok, big_h} = SampledHash.hash_file(big, byte_size(bytes))

      {:ok, small_h} =
        SampledHash.hash_file(small, SampledHash.min_sampled_size() + 1000)

      assert big_h != small_h
    end
  end
end
