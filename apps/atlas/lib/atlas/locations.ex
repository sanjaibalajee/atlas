defmodule Atlas.Locations do
  @moduledoc """
  Manage Atlas's watched locations.

  Adding a location is the Phase 1 user-facing entry point:

      1. append a `LocationAdded` event
      2. wait for the projector to catch up
      3. run an initial index of the directory (as FileIndexed events)
      4. start a filesystem watcher under `Atlas.Watcher.Supervisor`

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

  @doc """
  Add `path` as a watched location. Appends event, runs initial index,
  starts watcher. Idempotent for a path that's already watched.
  """
  @spec add(Path.t()) :: {:ok, Location.t()} | {:error, term()}
  def add(path) do
    path = Path.expand(path)

    with {:ok, seq} <- Log.append(%Event.LocationAdded{v: 1, at: Event.now_us(), path: path}),
         :ok <- Projector.catch_up_to(seq),
         {:ok, _result} <- scan(path),
         {:ok, _pid} <- Atlas.Watcher.Supervisor.start_watching(path) do
      {:ok, get(path)}
    end
  end

  @doc """
  Run an indexing scan over `path`, bracketing it with
  `LocationScanStarted` / `LocationScanCompleted` events so the
  projection's `scan_started_at_us` and `last_scanned_at_us` track the
  scan's lifecycle.

  A crashed process leaves `scan_started_at_us > last_scanned_at_us` —
  the clear signal that an indexing run was interrupted. The next
  `scan/1` is cheap (M1.2's incremental path skips already-indexed files).
  """
  @spec scan(Path.t()) :: {:ok, map()} | {:error, term()}
  def scan(path) do
    path = Path.expand(path)

    {:ok, _seq_start} =
      Log.append(%Event.LocationScanStarted{v: 1, at: Event.now_us(), path: path})

    t0 = System.monotonic_time(:microsecond)

    case Atlas.Indexer.index(path) do
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
        # Files under a tombstoned location are NOT deleted by the projector
        # (they retain their own deleted_at_us as nil — the location's
        # tombstone is enough for UI filtering). Their chunks therefore
        # don't become orphans just because the location was removed, so
        # no eager GC call here. `Atlas.Maintenance` sweeps periodically
        # for the general case (file churn, re-indexing, etc.).
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
end
