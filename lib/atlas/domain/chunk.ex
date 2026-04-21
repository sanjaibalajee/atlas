defmodule Atlas.Domain.Chunk do
  @moduledoc """
  One content-defined chunk of a file.

  Produced by `Atlas.Native.chunk_file/1` (FastCDC + BLAKE3 per chunk).
  Struct layout is mirrored in `native/atlas_native/src/chunking.rs` via
  `#[derive(NifStruct)]` — changing either side requires changing both.
  """

  @enforce_keys [:offset, :length, :hash]
  defstruct [:offset, :length, :hash]

  @type t :: %__MODULE__{
          offset: non_neg_integer(),
          length: pos_integer(),
          hash: Atlas.Domain.Hash.t()
        }

  @doc "Sum of chunk lengths — should equal the file size."
  @spec total_size([t()]) :: non_neg_integer()
  def total_size(chunks), do: Enum.reduce(chunks, 0, &(&1.length + &2))

  @doc """
  Merkle-like root hash for a file: BLAKE3 over the concatenation of all
  chunk hashes in order. Changes to chunk order or contents propagate.
  Phase 1 will upgrade this to a proper binary Merkle tree.
  """
  @spec root_hash([t()]) :: Atlas.Domain.Hash.t()
  def root_hash(chunks) do
    chunks
    |> Enum.map(& &1.hash)
    |> IO.iodata_to_binary()
    |> Atlas.Native.hash_bytes()
  end
end
