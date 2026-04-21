defmodule Atlas.Store.LocalFs do
  @moduledoc """
  Local-filesystem implementation of `Atlas.Store`.

  Layout: a chunk with hex hash `ab12…` lives at
  `<data_dir>/store/ab/12…`. The two-character shard prefix keeps any one
  directory from growing unmanageably large.

  Writes are atomic: the payload is written to a temp file in the same
  shard directory and then renamed into place. Readers never observe a
  partial write.

  Operations run in the caller's process; the GenServer exists only to
  own lifecycle (directory creation) and to be supervised.
  """

  @behaviour Atlas.Store
  use GenServer
  require Logger

  # --- Atlas.Store callbacks (module-level; not GenServer calls) ---

  @impl Atlas.Store
  def put_chunk(bin) when is_binary(bin) do
    hash = Atlas.Native.hash_bytes(bin)
    path = chunk_path(hash)

    if File.exists?(path) do
      {:ok, hash}
    else
      File.mkdir_p!(Path.dirname(path))
      tmp = "#{path}.tmp.#{System.unique_integer([:positive])}"

      try do
        File.write!(tmp, bin, [:binary])
        File.rename!(tmp, path)
        {:ok, hash}
      rescue
        e ->
          _ = File.rm(tmp)
          reraise e, __STACKTRACE__
      end
    end
  end

  @impl Atlas.Store
  def get_chunk(hash) do
    case File.read(chunk_path(hash)) do
      {:ok, bin} -> {:ok, bin}
      {:error, :enoent} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl Atlas.Store
  def has_chunk?(hash), do: File.exists?(chunk_path(hash))

  # --- GenServer lifecycle ---

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl GenServer
  def init(_opts) do
    File.mkdir_p!(Atlas.store_dir())
    Logger.debug("store.local_fs ready at #{Atlas.store_dir()}")
    {:ok, %{root: Atlas.store_dir()}}
  end

  # --- Internal ---

  defp chunk_path(hash) do
    hex = Atlas.Domain.Hash.to_hex(hash)
    <<shard::binary-size(2), rest::binary>> = hex
    Path.join([Atlas.store_dir(), shard, rest])
  end
end
