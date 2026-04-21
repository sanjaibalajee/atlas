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

  At init, the watcher snapshots the location's `ignore_patterns` from
  the projection and compiles them into an `Atlas.Indexer.Ignore` matcher.
  FS events whose path (relative to the location root) matches the
  patterns are dropped before the indexer is touched. To pick up a
  changed pattern list, `Atlas.Locations.set_ignore/2` stops and restarts
  the watcher; the new process loads the fresh patterns from the projection.
  """

  use GenServer
  require Logger

  alias Atlas.Domain.Event
  alias Atlas.Indexer.Ignore

  # --- Client API ---

  @type mode :: :shallow | :content
  @type start_arg :: Path.t() | {Path.t(), [String.t()]} | {Path.t(), [String.t()], mode()}

  def start_link(path) when is_binary(path), do: start_link({path, nil, :shallow})
  def start_link({path, patterns}) when is_binary(path), do: start_link({path, patterns, :shallow})

  def start_link({path, patterns, mode}) when is_binary(path) do
    path = Path.expand(path)
    GenServer.start_link(__MODULE__, {path, patterns, mode}, name: via(path))
  end

  def child_spec({_path, _patterns, _mode} = arg) do
    {path, _, _} = arg

    %{
      id: {__MODULE__, Path.expand(path)},
      start: {__MODULE__, :start_link, [arg]},
      restart: :transient
    }
  end

  def child_spec({path, patterns}) when is_binary(path),
    do: child_spec({path, patterns, :shallow})

  def child_spec(path) when is_binary(path), do: child_spec({path, nil, :shallow})

  @doc "Via-tuple for looking up the watcher for `path`."
  def via(path), do: {:via, Registry, {Atlas.Watcher.Registry, Path.expand(path)}}

  # --- GenServer ---

  @impl true
  def init({path, patterns, mode}) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :directory}} ->
        {:ok, fs_pid} = FileSystem.start_link(dirs: [path])
        :ok = FileSystem.subscribe(fs_pid)
        ignore = Ignore.compile(patterns || [])
        Logger.info("watcher: watching #{path} (mode: #{mode})")
        {:ok, %{path: path, fs: fs_pid, ignore: ignore, mode: mode}}

      _ ->
        {:stop, {:not_a_directory, path}}
    end
  end

  @impl true
  def handle_info({:file_event, _fs_pid, {changed_path, _events}}, state) do
    react(normalize(changed_path), state)
    {:noreply, state}
  end

  def handle_info({:file_event, _fs_pid, :stop}, state) do
    Logger.info("watcher: filesystem stop for #{state.path}")
    {:stop, :normal, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # --- Private ---

  defp react(changed_path, %{path: root, ignore: ignore, mode: mode}) do
    cond do
      # Hard invariant: never react to events inside Atlas's own state dir.
      # A chunk-write's temp file firing a FileDeleted through the indexer
      # would loop back into the store and spam the log. We check two
      # ways: the structured prefix list from `Atlas.internal_path?/1` and
      # a coarse suffix-substring fallback for `priv/data/store/` that
      # protects even if prefix matching misbehaves (e.g. unusual mount
      # setups). Belt + braces — the cost of a false positive in the
      # store dir is zero; the cost of a false negative is a runaway loop.
      Atlas.internal_path?(changed_path) -> :ignore
      looks_like_atlas_store?(changed_path) -> :ignore
      ignored?(changed_path, root, ignore) -> :ignore
      true -> do_react(changed_path, mode)
    end
  end

  # Coarse substring match. Intentional belt-and-braces to `internal_path?`
  # in case a realpath resolution fails in some future environment.
  defp looks_like_atlas_store?(path) do
    String.contains?(path, "/priv/data/store/")
  end

  defp do_react(path, mode) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular}} ->
        Atlas.Indexer.index_file(path, mode)

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

  defp ignored?(changed_path, root, ignore) do
    case relative(changed_path, root) do
      nil -> false
      rel -> Ignore.match?(ignore, rel)
    end
  end

  defp relative(path, root) do
    case Path.relative_to(path, root) do
      # relative_to returns the input unchanged when `path` is not under
      # `root`. In that case we have no sensible ignore match.
      ^path -> nil
      rel -> rel
    end
  end

  # macOS FSEvents reports canonicalised paths with the `/private` prefix
  # (`/tmp` → `/private/tmp`, `/var` → `/private/var`). User-supplied
  # location paths don't have that prefix, so events with canonical paths
  # would miss longest-prefix location matching and create duplicate
  # projection rows. Strip the `/private` prefix so every path the log and
  # broadcaster see matches the location path the user typed.
  #
  # Match directory boundaries precisely: `/private/tmp` exactly, or
  # `/private/tmp/` followed by any suffix. Without the trailing-slash
  # discipline, the clause would also rewrite unrelated paths like
  # `/private/tmpfoo` → `/tmpfoo`.
  @doc false
  @spec normalize(String.t()) :: String.t()
  def normalize("/private/tmp"), do: "/tmp"
  def normalize("/private/tmp/" <> rest), do: "/tmp/" <> rest
  def normalize("/private/var"), do: "/var"
  def normalize("/private/var/" <> rest), do: "/var/" <> rest
  def normalize(path), do: path
end
