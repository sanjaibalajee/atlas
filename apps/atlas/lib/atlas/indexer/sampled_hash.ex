defmodule Atlas.Indexer.SampledHash do
  @moduledoc """
  Sampled content hashing for **shallow** index mode.

  The default full-chunking path reads every byte of a file and writes
  the chunks into the local CAS. That's ~1× the source size on disk and
  pays for features (P2P sync, chunk-addressable reads for extensions)
  that aren't live yet. For a "just browse my files" workflow, it's
  pure overhead.

  This module produces a stable BLAKE3 digest from a **small sample** of
  the file — 8 KB header + 4 × 10 KB interior samples + 8 KB tail + the
  file size as a little-endian u64. Same scheme Spacedrive uses for its
  content-id when full-content indexing isn't needed. The resulting
  digest changes when the content changes (at any of the sampled
  regions) but is several orders of magnitude cheaper to compute and
  requires no CAS writes.

  Files below `min_sampled_size/0` (100 KB) are hashed in full — the
  sampling overhead would match or exceed the file size.
  """

  @header_size 8 * 1024
  @tail_size 8 * 1024
  @sample_size 10 * 1024
  @sample_count 4

  # Below this the sampled-hash approach would read as many bytes as a
  # full hash — pointless, and the digest would also depend on sample
  # positions which adds no real information. So hash the whole file.
  @min_sampled_size @header_size + @sample_size * @sample_count + @tail_size

  @doc "Minimum file size at which we switch from full-file hash to sampling."
  @spec min_sampled_size() :: pos_integer()
  def min_sampled_size, do: @min_sampled_size

  @doc """
  Compute the sampled content hash of a file. For files smaller than
  `min_sampled_size/0`, this is equivalent to `Atlas.Native.hash_file/1`.

  Returns `{:ok, <<_::256>>} | {:error, reason}`.
  """
  @spec hash_file(Path.t(), non_neg_integer()) ::
          {:ok, binary()} | {:error, term()}
  def hash_file(path, size) when is_integer(size) and size >= 0 do
    cond do
      size < @min_sampled_size ->
        Atlas.Native.hash_file(path)

      true ->
        with {:ok, fd} <- :file.open(path, [:read, :binary, :raw]) do
          try do
            sampled = assemble_samples(fd, size)
            {:ok, Atlas.Native.hash_bytes(sampled)}
          after
            :file.close(fd)
          end
        end
    end
  end

  # --- Private ---

  defp assemble_samples(fd, size) do
    head = read_at(fd, 0, @header_size)
    tail = read_at(fd, size - @tail_size, @tail_size)

    middles =
      for i <- 1..@sample_count do
        # Evenly spread N samples in the middle of the file, skipping
        # the regions already covered by head + tail.
        interior = size - @header_size - @tail_size
        stride = div(interior, @sample_count + 1)
        offset = @header_size + stride * i
        read_at(fd, offset, @sample_size)
      end

    # Include size as a little-endian u64 so two files that happen to
    # share sampled bytes but differ in length produce different digests.
    size_tag = <<size::little-unsigned-integer-size(64)>>

    IO.iodata_to_binary([head, middles, tail, size_tag])
  end

  defp read_at(fd, offset, count) do
    {:ok, _} = :file.position(fd, offset)

    case :file.read(fd, count) do
      {:ok, bytes} -> bytes
      :eof -> <<>>
    end
  end
end
