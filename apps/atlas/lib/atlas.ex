defmodule Atlas do
  @moduledoc """
  Atlas — a content-addressed, event-sourced file system.

  This module is the public API facade. Internal modules are grouped as:

    * `Atlas.Domain.*`     — pure value objects
    * `Atlas.Store.*`      — content-addressed object store
    * `Atlas.Log.*`        — append-only event log (source of truth)
    * `Atlas.Projection.*` — read-model projectors (event → Ecto)
    * `Atlas.Indexer.*`    — file walker + chunker + event producer
    * `Atlas.Native`       — Rust NIF (BLAKE3 + FastCDC)
  """

  @doc """
  Return the configured root directory for runtime state.

  All persistent data — the object store, the event log, the projection
  database — lives under this directory. Relative values are resolved
  against the `:atlas` app's `priv` dir so paths work regardless of CWD
  (important now that Atlas lives inside an umbrella).
  """
  @spec data_dir() :: Path.t()
  def data_dir do
    resolve_data_path(Application.fetch_env!(:atlas, :data_dir))
  end

  @doc "Absolute path to the chunk store root."
  @spec store_dir() :: Path.t()
  def store_dir, do: Path.join(data_dir(), "store")

  @doc "Absolute path to the event log database."
  @spec log_db_path() :: Path.t()
  def log_db_path, do: Path.join(data_dir(), "log.db")

  @doc "Absolute path to the projection database."
  @spec projection_db_path() :: Path.t()
  def projection_db_path, do: Path.join(data_dir(), "projection.db")

  @doc false
  @spec resolve_data_path(Path.t()) :: Path.t()
  def resolve_data_path(path) do
    case Path.type(path) do
      :absolute -> path
      _ -> Path.join(:code.priv_dir(:atlas), path)
    end
  end

  @doc """
  True if `path` is inside Atlas's own on-disk state (log DB, projection
  DB, chunk CAS). The walker and watcher skip these unconditionally —
  otherwise pointing Atlas at a parent directory that contains its own
  `priv/data/store/` triggers a feedback loop: each CAS write creates a
  temp file, the watcher fires, the indexer re-enters the CAS, rinse.

  In dev, `Atlas.data_dir/0` resolves via `:code.priv_dir(:atlas)` which
  points at `_build/<env>/lib/atlas/priv/data` — a symlink to the real
  `apps/atlas/priv/data`. FSEvents delivers paths with the symlink
  resolved, so the check must consider both the symlinked and realpath
  variants. `internal_path_prefixes/0` returns the deduped list.
  """
  @spec internal_path?(Path.t()) :: boolean()
  def internal_path?(path) when is_binary(path) do
    Enum.any?(internal_path_prefixes(), fn prefix ->
      path == prefix or String.starts_with?(path, prefix <> "/")
    end)
  rescue
    _ -> false
  end

  @doc """
  Every prefix that should be considered "Atlas-internal" — the data dir
  as-configured plus its realpath form (deref'd through any symlink
  chain). In prod these usually collapse to one entry.
  """
  @spec internal_path_prefixes() :: [Path.t()]
  def internal_path_prefixes do
    data = data_dir()
    resolved = realpath(data)

    [data, resolved]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  # Best-effort realpath: walk components from root, following any
  # symlinks encountered. Iterates to a fixed point so cascaded symlinks
  # resolve fully. Returns `nil` if the path doesn't exist.
  defp realpath(path) when is_binary(path) do
    expanded = Path.expand(path)

    case resolve(expanded) do
      ^expanded -> expanded
      other -> realpath(other)
    end
  rescue
    _ -> path
  end

  defp realpath(_), do: nil

  defp resolve(path) do
    path
    |> Path.split()
    |> Enum.reduce("", fn seg, acc ->
      candidate =
        case {acc, seg} do
          {"", "/"} -> "/"
          {"", seg} -> seg
          {acc, seg} -> Path.join(acc, seg)
        end

      case :file.read_link(String.to_charlist(candidate)) do
        {:ok, target} ->
          target_str = IO.chardata_to_string(target)

          if Path.type(target_str) == :absolute do
            target_str
          else
            Path.join(Path.dirname(candidate), target_str)
          end

        _ ->
          candidate
      end
    end)
  end
end
