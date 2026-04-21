defmodule Atlas.Store do
  @moduledoc """
  Content-addressed object store — the "bytes" half of Atlas.

  The only identifier a stored chunk has is its BLAKE3 hash. Writes are
  idempotent: putting a chunk that already exists is a silent no-op.
  Reads return `{:error, :not_found}` rather than raising.

  The concrete backend is configurable via the `:atlas, :store_backend`
  application env. Default is `Atlas.Store.LocalFs`.
  """

  @type hash :: Atlas.Domain.Hash.t()

  @callback put_chunk(binary()) :: {:ok, hash()} | {:error, term()}
  @callback get_chunk(hash()) :: {:ok, binary()} | {:error, :not_found | term()}
  @callback has_chunk?(hash()) :: boolean()

  @spec put_chunk(binary()) :: {:ok, hash()} | {:error, term()}
  def put_chunk(bin), do: backend().put_chunk(bin)

  @spec get_chunk(hash()) :: {:ok, binary()} | {:error, :not_found | term()}
  def get_chunk(hash), do: backend().get_chunk(hash)

  @spec has_chunk?(hash()) :: boolean()
  def has_chunk?(hash), do: backend().has_chunk?(hash)

  defp backend do
    Application.get_env(:atlas, :store_backend, Atlas.Store.LocalFs)
  end
end
