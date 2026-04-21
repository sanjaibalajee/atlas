defmodule Atlas.Domain.Hash do
  @moduledoc """
  A BLAKE3 content hash: 32 bytes, rendered as lowercase hex for display.

  This is a thin wrapper around a binary. No struct — keeping the raw
  binary representation means we can pass it to Ecto and the NIF without
  unwrapping. The helpers here are for validation, display, and routing
  (the first hex byte is the shard directory in the object store).
  """

  @type t :: <<_::256>>

  @hex_byte_size 32
  @hex_string_size 64

  @doc "Build a hash from 64 hex characters. Returns `{:ok, hash}` or `{:error, reason}`."
  @spec from_hex(String.t()) :: {:ok, t()} | {:error, :invalid_hex}
  def from_hex(hex) when is_binary(hex) and byte_size(hex) == @hex_string_size do
    case Base.decode16(hex, case: :mixed) do
      {:ok, bin} when byte_size(bin) == @hex_byte_size -> {:ok, bin}
      _ -> {:error, :invalid_hex}
    end
  end

  def from_hex(_), do: {:error, :invalid_hex}

  @doc "Render a hash as lowercase hex."
  @spec to_hex(t()) :: String.t()
  def to_hex(hash) when is_binary(hash) and byte_size(hash) == @hex_byte_size do
    Base.encode16(hash, case: :lower)
  end

  @doc "First `n` hex chars of a hash, for display. Defaults to 8."
  @spec short(t(), pos_integer()) :: String.t()
  def short(hash, n \\ 8), do: binary_part(to_hex(hash), 0, n)

  @doc "Routing prefix for the object store. First hex byte = 2 chars."
  @spec shard(t()) :: String.t()
  def shard(hash), do: binary_part(to_hex(hash), 0, 2)

  @doc "Is `bin` a valid hash (32 raw bytes)?"
  @spec valid?(any()) :: boolean()
  def valid?(bin) when is_binary(bin) and byte_size(bin) == @hex_byte_size, do: true
  def valid?(_), do: false
end
