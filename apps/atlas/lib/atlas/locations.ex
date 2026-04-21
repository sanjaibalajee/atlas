defmodule Atlas.Locations do
  @moduledoc """
  Manage Atlas's watched locations.

  Adding a location is the Phase 1 user-facing entry point:

      1. append a `LocationAdded` event
      2. wait for the projector to catch up
      3. seed default ignore patterns (if first-add for this path)
      4. optionally append `LocationModeSet` when the caller asked for
         non-default indexing
      5. run an initial index of the directory (as `FileIndexed` events)
      6. start a filesystem watcher under `Atlas.Watcher.Supervisor`

  Removal is the mirror: stop the watcher, append `LocationRemoved`. The
  location row in the projection becomes a tombstone (non-nil
  `removed_at_us`); we never hard-delete so past events still have context.
  """

  import Ecto.Query

  alias Atlas.Domain.Event
  alias Atlas.Log
  alias Atlas.Projection.Projector
  alias Atlas.Repo
  alias Atlas.Schemas.Location

  @default_mode :shallow

  @type add_opts :: [mode: :shallow | :content]

  @doc """
  Add `path` as a watched location. Appends event, seeds defaults, runs
  initial index, starts watcher. Idempotent for already-watched paths.

  ## Options

    * `:mode` — `:shallow` (default; sampled hash, no CAS writes) or
      `:content` (full FastCDC chunking, required for future P2P sync).
  """
  @spec add(Path.t(), add_opts()) :: {:ok, Location.t()} | {:error, term()}
  def add(path, opts \\ []) do
    path = Path.expand(path)
    mode = validate_mode!(Keyword.get(opts, :mode, @default_mode))

    with :ok <- validate_not_internal(path),
         {:ok, seq} <-
           Log.append(%Event.LocationAdded{v: 1, at: Event.now_us(), path: path}),
         :ok <- Projector.catch_up_to(seq),
         :ok <- maybe_seed_defaults(path),
         :ok <- maybe_set_mode(path, mode),
         {:ok, _result} <- scan(path),
         {:ok, _pid} <-
           Atlas.Watcher.Supervisor.start_watching(path, ignore_patterns_for(path), mode) do
      {:ok, get(path)}
    end
  end

  defp validate_mode!(mode) when mode in [:shallow, :content], do: mode

  defp validate_mode!(other),
    do: raise(ArgumentError, "invalid index_mode: #{inspect(other)}")

  # Atlas stores its own log, projection, and chunk CAS under
  # `Atlas.data_dir/0`. Watching a parent directory that contains that
  # path creates a feedback loop where every chunk write triggers an
  # indexer event. The walker + watcher already skip internal paths as a
  # belt-and-braces guard; rejecting `add/1` up-front makes the error
  # loud and actionable instead of silently producing a half-broken
  # location.
  #
  # Check against every internal prefix (includes realpath-resolved
  # versions) so dev-mode `_build/` symlinks don't let a CAS-containing
  # parent slip through.
  defp validate_not_internal(path) do
    prefixes = Atlas.internal_path_prefixes()

    cond do
      Enum.any?(prefixes, &(&1 == path)) ->
        {:error, :atlas_internal_path}

      Enum.any?(prefixes, &String.starts_with?(path, &1 <> "/")) ->
        {:error, :atlas_internal_path}

      Enum.any?(prefixes, &String.starts_with?(&1, path <> "/")) ->
        {:error, :contains_atlas_internal_path}

      true ->
        :ok
    end
  end

  @doc """
  Replace the ignore-pattern list for a watched location. Appends a
  `LocationIgnoreSet` event, then restarts the watcher so it loads the
  fresh compiled matcher. The next scan uses the new patterns too.

  Returns `:ok` or `{:error, :not_found}` when the path isn't an
  active location.
  """
  @spec set_ignore(Path.t(), [String.t()]) :: :ok | {:error, term()}
  def set_ignore(path, patterns) when is_list(patterns) do
    path = Path.expand(path)
    patterns = sanitize_patterns(patterns)

    case get(path) do
      nil ->
        {:error, :not_found}

      %Location{removed_at_us: t} when is_integer(t) ->
        {:error, :not_found}

      %Location{} = loc ->
        with {:ok, seq} <-
               Log.append(%Event.LocationIgnoreSet{
                 v: 1,
                 at: Event.now_us(),
                 path: path,
                 patterns: patterns
               }),
             :ok <- Projector.catch_up_to(seq) do
          bounce_watcher(path, patterns, mode_for(loc))
          :ok
        end
    end
  end

  @doc """
  Switch a location between `:shallow` and `:content` indexing modes.

  Appends a `LocationModeSet` event and restarts the watcher so the new
  event-driven indexing reflects the change. Does NOT retroactively
  rescan — call `scan/1` if you want existing files re-hashed under the
  new mode.
  """
  @spec set_mode(Path.t(), :shallow | :content) :: :ok | {:error, term()}
  def set_mode(path, mode) when mode in [:shallow, :content] do
    path = Path.expand(path)

    case get(path) do
      nil ->
        {:error, :not_found}

      %Location{removed_at_us: t} when is_integer(t) ->
        {:error, :not_found}

      %Location{} = loc ->
        with {:ok, seq} <-
               Log.append(%Event.LocationModeSet{
                 v: 1,
                 at: Event.now_us(),
                 path: path,
                 mode: mode
               }),
             :ok <- Projector.catch_up_to(seq) do
          bounce_watcher(path, loc.ignore_patterns || [], mode)
          :ok
        end
    end
  end

  defp bounce_watcher(path, patterns, mode) do
    # Caller's process can already talk to the Repo; the watcher
    # intentionally never does. Passing patterns + mode in keeps the
    # watcher's init DB-free.
    _ = Atlas.Watcher.Supervisor.stop_watching(path)
    {:ok, _pid} = Atlas.Watcher.Supervisor.start_watching(path, patterns, mode)
    :ok
  end

  defp sanitize_patterns(patterns) do
    patterns
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  # First-add seeding: only apply the defaults if there are no patterns
  # yet. Calling `add/1` on an existing location preserves the user's
  # customisations.
  defp maybe_seed_defaults(path) do
    case get(path) do
      %Location{ignore_patterns: patterns} when is_list(patterns) and patterns != [] ->
        :ok

      %Location{} ->
        {:ok, seq} =
          Log.append(%Event.LocationIgnoreSet{
            v: 1,
            at: Event.now_us(),
            path: path,
            patterns: Atlas.Indexer.Ignore.default_patterns()
          })

        Projector.catch_up_to(seq)

      _ ->
        :ok
    end
  end

  # Only emit a `LocationModeSet` when the caller asked for something
  # other than the schema default. Keeps the log tidy for the common
  # "just add this folder" path.
  defp maybe_set_mode(_path, mode) when mode == @default_mode, do: :ok

  defp maybe_set_mode(path, mode) do
    {:ok, seq} =
      Log.append(%Event.LocationModeSet{
        v: 1,
        at: Event.now_us(),
        path: path,
        mode: mode
      })

    Projector.catch_up_to(seq)
  end

  @doc """
  Run an indexing scan over `path`, bracketing it with
  `LocationScanStarted` / `LocationScanCompleted` events so the
  projection's `scan_started_at_us` and `last_scanned_at_us` track the
  scan's lifecycle. Uses the location's current `index_mode`.

  A crashed process leaves `scan_started_at_us > last_scanned_at_us` —
  the clear signal that an indexing run was interrupted. The next
  `scan/1` is cheap (M1.2's incremental path skips already-indexed files).
  """
  @spec scan(Path.t()) :: {:ok, map()} | {:error, term()}
  def scan(path) do
    path = Path.expand(path)
    patterns = ignore_patterns_for(path)
    mode = mode_for_path(path)

    {:ok, _seq_start} =
      Log.append(%Event.LocationScanStarted{v: 1, at: Event.now_us(), path: path})

    t0 = System.monotonic_time(:microsecond)

    case Atlas.Indexer.index(path, ignore: patterns, mode: mode) do
      {:ok, result} ->
        duration_us = System.monotonic_time(:microsecond) - t0
        files_total = result.new + result.modified + result.unchanged

        {:ok, seq_end} =
          Log.append(%Event.LocationScanCompleted{
            v: 1,
            at: Event.now_us(),
            path: path,
            files: files_total,
            bytes: result.bytes,
            duration_us: duration_us
          })

        :ok = Projector.catch_up_to(seq_end)
        {:ok, result}

      other ->
        other
    end
  end

  @doc """
  Stop watching `path`. Terminates the watcher process (if running) and
  appends a `LocationRemoved` event. Files previously indexed under this
  location remain in the projection unless separately deleted.
  """
  @spec remove(Path.t()) :: :ok | {:error, term()}
  def remove(path) do
    path = Path.expand(path)

    _ = Atlas.Watcher.Supervisor.stop_watching(path)

    case Log.append(%Event.LocationRemoved{v: 1, at: Event.now_us(), path: path}) do
      {:ok, seq} ->
        :ok = Projector.catch_up_to(seq)
        :ok

      other ->
        other
    end
  end

  @doc "List currently active (non-tombstoned) locations, ordered by path."
  @spec list() :: [Location.t()]
  def list do
    Repo.all(
      from l in Location,
        where: is_nil(l.removed_at_us),
        order_by: [asc: l.path]
    )
  end

  @doc "List every location ever added, including tombstoned ones."
  @spec all() :: [Location.t()]
  def all do
    Repo.all(from l in Location, order_by: [asc: l.path])
  end

  @doc "Fetch one location by path. Returns `nil` if unknown."
  @spec get(Path.t()) :: Location.t() | nil
  def get(path), do: Repo.get_by(Location, path: Path.expand(path))

  # Read the current ignore patterns from the projection for the given
  # location path. Returns `[]` if the location is unknown, so the indexer
  # runs unfiltered (correct for one-shot `mix atlas.index` calls on
  # paths that aren't yet registered locations). Called from processes
  # that are already allowed to query the Repo (tests' test pid, the
  # top-level app supervisor, CLI tasks) — never from the watcher init.
  defp ignore_patterns_for(path) do
    case get(path) do
      nil -> []
      %Location{ignore_patterns: patterns} -> patterns || []
    end
  rescue
    _ -> []
  end

  defp mode_for_path(path) do
    case get(path) do
      nil -> @default_mode
      loc -> mode_for(loc)
    end
  rescue
    _ -> @default_mode
  end

  defp mode_for(%Location{index_mode: "content"}), do: :content
  defp mode_for(%Location{}), do: :shallow
end
