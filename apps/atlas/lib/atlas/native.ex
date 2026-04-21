defmodule Atlas.Native do
  @moduledoc """
  Rust NIF bindings. See `native/atlas_native/` for the implementation.

  The functions below declare signatures the compiler can check and Dialyzer
  can reason about. At runtime they are replaced by the loaded NIF; if the
  NIF fails to load, the fallback bodies raise `:nif_not_loaded`.
  """

  use Rustler, otp_app: :atlas, crate: "atlas_native"

  @type hash :: <<_::256>>
  @type chunk :: Atlas.Domain.Chunk.t()

  @doc "BLAKE3 hash of an in-memory binary."
  @spec hash_bytes(binary()) :: hash()
  def hash_bytes(_bytes), do: :erlang.nif_error(:nif_not_loaded)

  @doc "BLAKE3 hash of a file, streamed from disk."
  @spec hash_file(Path.t()) :: {:ok, hash()} | {:error, String.t()}
  def hash_file(_path), do: :erlang.nif_error(:nif_not_loaded)

  @doc "FastCDC-chunk an in-memory binary and hash each chunk."
  @spec chunk_bytes(binary()) :: [chunk()]
  def chunk_bytes(_bytes), do: :erlang.nif_error(:nif_not_loaded)

  @doc "FastCDC-chunk a file and hash each chunk. Reads the whole file into RAM."
  @spec chunk_file(Path.t()) :: {:ok, [chunk()]} | {:error, String.t()}
  def chunk_file(_path), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Stream a file through FastCDC and write each chunk into the CAS rooted
  at `store_root`. Returns only the chunk metadata — no bytes cross the
  NIF boundary after the chunker. Used by the indexer's hot path.

  Memory is bounded by the configured max chunk size (~256 KB), so this is
  safe on arbitrarily large files.
  """
  @spec chunk_and_store_file(Path.t(), Path.t()) :: {:ok, [chunk()]} | {:error, String.t()}
  def chunk_and_store_file(_path, _store_root), do: :erlang.nif_error(:nif_not_loaded)
end
