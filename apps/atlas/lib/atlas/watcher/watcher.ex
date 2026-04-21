defmodule Atlas.Watcher do
  @moduledoc """
  One `GenServer` per watched location. Subscribes to the underlying
  `FileSystem` process and translates OS events into Atlas events.

  Phase 1 strategy is intentionally simple and robust to FSEvent quirks:

      * on ANY event for a path: stat it.
        - regular file present → hand the path to `Atlas.Indexer.index_file/1`
          which decides new / modified / unchanged.
        - path gone → append a `FileDeleted` event.
        - anything else (directory, symlink, permission-denied) → ignore.

  This avoids parsing `:created`/`:modified`/`:removed` bundles, which
  FSEvents can reorder, coalesce, or duplicate. Because the indexer is
  incremental (M1.2), triggering it on every notification is cheap — a
  stat and a lookup for unchanged files.
  """

  use GenServer
  require Logger

  alias Atlas.Domain.Event

  # --- Client API ---

  def start_link(path) when is_binary(path) do
    path = Path.expand(path)
    GenServer.start_link(__MODULE__, path, name: via(path))
  end

  def child_spec(path) do
    %{
      id: {__MODULE__, Path.expand(path)},
      start: {__MODULE__, :start_link, [path]},
      restart: :transient
    }
  end

  @doc "Via-tuple for looking up the watcher for `path`."
  def via(path), do: {:via, Registry, {Atlas.Watcher.Registry, Path.expand(path)}}

  # --- GenServer ---

  @impl true
  def init(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :directory}} ->
        {:ok, fs_pid} = FileSystem.start_link(dirs: [path])
        :ok = FileSystem.subscribe(fs_pid)
        Logger.info("watcher: watching #{path}")
        {:ok, %{path: path, fs: fs_pid}}

      _ ->
        {:stop, {:not_a_directory, path}}
    end
  end

  @impl true
  def handle_info({:file_event, _fs_pid, {changed_path, _events}}, state) do
    react(normalize(changed_path))
    {:noreply, state}
  end

  def handle_info({:file_event, _fs_pid, :stop}, state) do
    Logger.info("watcher: filesystem stop for #{state.path}")
    {:stop, :normal, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # --- Private ---

  defp react(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular}} ->
        Atlas.Indexer.index_file(path)

      {:ok, _other} ->
        :ignore

      {:error, :enoent} ->
        Atlas.Log.append(%Event.FileDeleted{
          v: 1,
          at: Event.now_us(),
          path: path
        })

      {:error, _reason} ->
        :ignore
    end
  end

  # macOS FSEvents reports canonicalised paths with the `/private` prefix
  # (`/tmp` → `/private/tmp`, `/var` → `/private/var`). User-supplied
  # location paths don't have that prefix, so events with canonical paths
  # would miss longest-prefix location matching and create duplicate
  # projection rows. Strip the `/private` prefix so every path the log and
  # broadcaster see matches the location path the user typed.
  @doc false
  @spec normalize(String.t()) :: String.t()
  def normalize("/private/tmp" <> rest), do: "/tmp" <> rest
  def normalize("/private/var" <> rest), do: "/var" <> rest
  def normalize(path), do: path
end
