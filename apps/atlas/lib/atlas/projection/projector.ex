defmodule Atlas.Projection.Projector do
  @moduledoc """
  Consumes events from `Atlas.Log` and maintains the read model in
  `Atlas.Repo`.

  On boot we read `projection_state.last_applied_seq` and catch up. After
  that, we receive `{:event_appended, seq}` notifications from
  `Atlas.Log.Notifier` and incrementally apply pending events.

  After each event commits, the projector broadcasts a change message on
  `Atlas.PubSub` so LiveView (and other PubSub-backed consumers) can react
  without polling. The broadcast always happens **after** the projection
  transaction commits — PubSub is advisory and must not block durability.

  An in-process cache of active locations (`{id, path}`) is maintained in
  GenServer state. It's rebuilt at init and on any `LocationAdded` /
  `LocationRemoved` event. This lets the broadcaster resolve a file path
  to a `location_id` without touching the DB on every file event.

  `rebuild/0` drops the projection tables, re-runs migrations, and replays
  the entire log. This is the test that proves the log is the only source
  of truth.
  """

  use GenServer
  require Logger

  alias Atlas.Domain.Event
  alias Atlas.Log.Notifier
  alias Atlas.Repo
  alias Atlas.Schemas.{Chunk, FileChunk, Location, ProjectionState}
  alias Atlas.Schemas.File, as: FileRow

  import Ecto.Query, only: [from: 2]

  # --- Public API ---

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Block until the projector has applied up through at least `target_seq`."
  @spec catch_up_to(non_neg_integer(), timeout()) :: :ok
  def catch_up_to(target_seq, timeout \\ 10_000) do
    GenServer.call(__MODULE__, {:catch_up_to, target_seq}, timeout)
  end

  @doc "Drop projection tables and replay the entire event log."
  @spec rebuild() :: :ok
  def rebuild, do: GenServer.call(__MODULE__, :rebuild, :infinity)

  # --- GenServer ---

  @impl true
  def init(_opts) do
    last_seq = load_last_applied_seq()
    :ok = Notifier.subscribe()
    # Catch up once after init returns. Any broadcasts that arrive before
    # this message fire enqueue behind it (mailbox is FIFO), so no events
    # can be missed even during startup.
    send(self(), :catch_up)
    {:ok, %{last_seq: last_seq, active_locations: load_active_locations()}}
  end

  @impl true
  def handle_info(:catch_up, state), do: {:noreply, catch_up(state, :infinity)}

  def handle_info({:event_appended, _seq}, state),
    do: {:noreply, catch_up(state, :infinity)}

  @impl true
  def handle_call({:catch_up_to, target}, _from, state) do
    new_state = catch_up(state, target)
    {:reply, :ok, new_state}
  end

  def handle_call(:rebuild, _from, state) do
    Logger.info("projection: rebuilding from log")
    :ok = drop_and_remigrate()
    new_state = catch_up(%{state | last_seq: 0, active_locations: []}, :infinity)
    {:reply, :ok, new_state}
  end

  # --- Core replay loop ---

  defp catch_up(state, target) do
    state.last_seq
    |> Atlas.Log.stream()
    |> Enum.reduce_while(state, fn {seq, event}, acc ->
      cond do
        target != :infinity and seq > target ->
          {:halt, acc}

        true ->
          {:ok, ctx} = apply_and_advance(event, seq)
          new_locations = maybe_refresh_locations(acc.active_locations, event)
          broadcast_change(event, seq, ctx, new_locations)
          {:cont, %{acc | last_seq: seq, active_locations: new_locations}}
      end
    end)
  end

  defp apply_and_advance(event, seq) do
    Repo.transaction(fn ->
      {:ok, ctx} = apply_event(event)
      :ok = save_last_applied_seq(seq)
      ctx
    end)
  end

  # --- Event handlers ---
  #
  # Each returns `{:ok, ctx}` where `ctx` carries extra fields the
  # broadcaster needs (file_id, etc.) that aren't already in the event.

  # FileIndexed and FileModified have identical projection semantics —
  # both upsert the file row by path and replace its chunk mappings.
  defp apply_event(%Event.FileIndexed{} = e) do
    {:ok, file} = upsert_file_with_chunks(e)
    {:ok, %{file_id: file.id}}
  end

  defp apply_event(%Event.FileModified{} = e) do
    {:ok, file} = upsert_file_with_chunks(e)
    {:ok, %{file_id: file.id}}
  end

  defp apply_event(%Event.FileMoved{from_path: from, to_path: to}) do
    Repo.update_all(
      from(f in FileRow, where: f.path == ^from),
      set: [path: to]
    )

    file = Repo.get_by(FileRow, path: to)
    {:ok, %{file_id: file && file.id}}
  end

  defp apply_event(%Event.FileDeleted{path: path, at: at}) do
    case Repo.get_by(FileRow, path: path) do
      nil ->
        {:ok, %{file_id: nil}}

      %FileRow{id: id} = file ->
        old_hashes =
          Repo.all(
            from fc in FileChunk,
              where: fc.file_id == ^id,
              select: fc.chunk_hash
          )

        Repo.delete_all(from fc in FileChunk, where: fc.file_id == ^id)

        file
        |> Ecto.Changeset.change(deleted_at_us: at)
        |> Repo.update!()

        recompute_ref_counts(old_hashes)
        {:ok, %{file_id: id}}
    end
  end

  defp apply_event(%Event.LocationAdded{path: path, at: at}) do
    location =
      %Location{}
      |> Location.changeset(%{path: path, added_at_us: at, removed_at_us: nil})
      |> Repo.insert!(
        on_conflict: {:replace_all_except, [:id, :inserted_at]},
        conflict_target: :path,
        returning: true
      )

    {:ok, %{location_id: location.id}}
  end

  defp apply_event(%Event.LocationRemoved{path: path, at: at}) do
    Repo.update_all(
      from(l in Location, where: l.path == ^path),
      set: [removed_at_us: at]
    )

    location = Repo.get_by(Location, path: path)
    {:ok, %{location_id: location && location.id}}
  end

  defp apply_event(%Event.LocationScanStarted{path: path, at: at}) do
    Repo.update_all(
      from(l in Location, where: l.path == ^path),
      set: [scan_started_at_us: at]
    )

    location = Repo.get_by(Location, path: path)
    {:ok, %{location_id: location && location.id}}
  end

  defp apply_event(%Event.LocationScanCompleted{path: path, at: at}) do
    Repo.update_all(
      from(l in Location, where: l.path == ^path),
      set: [last_scanned_at_us: at]
    )

    location = Repo.get_by(Location, path: path)
    {:ok, %{location_id: location && location.id}}
  end

  # Progress events carry no durable state — the projection only cares about
  # terminal status. Subscribers (LiveView, metrics) read from PubSub.
  defp apply_event(%Event.LocationScanProgress{path: path}) do
    location = Repo.get_by(Location, path: path)
    {:ok, %{location_id: location && location.id}}
  end

  defp apply_event(%Event.LocationIgnoreSet{path: path, patterns: patterns}) do
    # `update_all` with a raw value bypasses Ecto.Type.dump for fields whose
    # custom types (here `Atlas.Schemas.JsonList`) serialize at dump time.
    # Fetching the changeset target and using `Repo.update!` routes the
    # list through JsonList so it lands on disk as JSON text.
    case Repo.get_by(Location, path: path) do
      %Location{} = loc ->
        loc
        |> Location.changeset(%{ignore_patterns: patterns})
        |> Repo.update!()

        {:ok, %{location_id: loc.id}}

      nil ->
        {:ok, %{location_id: nil}}
    end
  end

  defp apply_event(%Event.LocationModeSet{path: path, mode: mode}) do
    mode_str = to_string(mode)

    Repo.update_all(
      from(l in Location, where: l.path == ^path),
      set: [index_mode: mode_str]
    )

    location = Repo.get_by(Location, path: path)
    {:ok, %{location_id: location && location.id}}
  end

  defp upsert_file_with_chunks(e) do
    now = System.os_time(:microsecond)

    existing = Repo.get_by(FileRow, path: e.path)

    old_hashes =
      case existing do
        nil ->
          []

        %FileRow{id: id} ->
          Repo.all(
            from fc in FileChunk,
              where: fc.file_id == ^id,
              select: fc.chunk_hash
          )
      end

    file =
      %FileRow{}
      |> FileRow.upsert_changeset(%{
        path: e.path,
        size: e.size,
        mtime_us: e.mtime_us,
        root_hash: e.root_hash,
        deleted_at_us: nil,
        indexed_at_us: now
      })
      |> Repo.insert!(
        on_conflict: {:replace_all_except, [:id, :inserted_at]},
        conflict_target: :path,
        returning: true
      )

    Repo.delete_all(from(fc in FileChunk, where: fc.file_id == ^file.id))

    Enum.with_index(e.chunks, fn c, idx ->
      Repo.insert!(
        %Chunk{hash: c.hash, length: c.length, ref_count: 0},
        on_conflict: :nothing,
        conflict_target: :hash
      )

      Repo.insert!(%FileChunk{
        file_id: file.id,
        ordinal: idx,
        offset: c.offset,
        length: c.length,
        chunk_hash: c.hash
      })
    end)

    recompute_ref_counts(old_hashes ++ Enum.map(e.chunks, & &1.hash))
    {:ok, file}
  end

  defp recompute_ref_counts(hashes) do
    unique = Enum.uniq(hashes)

    counts =
      Repo.all(
        from fc in FileChunk,
          where: fc.chunk_hash in ^unique,
          group_by: fc.chunk_hash,
          select: {fc.chunk_hash, count(fc.chunk_hash)}
      )
      |> Map.new()

    Enum.each(unique, fn hash ->
      new_count = Map.get(counts, hash, 0)

      Repo.update_all(
        from(c in Chunk, where: c.hash == ^hash),
        set: [ref_count: new_count]
      )
    end)
  end

  # --- Active-locations cache ---

  defp load_active_locations do
    Repo.all(
      from l in Location,
        where: is_nil(l.removed_at_us),
        select: %{id: l.id, path: l.path},
        order_by: [desc: fragment("length(?)", l.path)]
    )
  rescue
    _ -> []
  end

  # Rebuild the cache only when a location was added or removed. Any other
  # event leaves the set of active locations unchanged.
  defp maybe_refresh_locations(_old, %Event.LocationAdded{}), do: load_active_locations()
  defp maybe_refresh_locations(_old, %Event.LocationRemoved{}), do: load_active_locations()
  defp maybe_refresh_locations(old, _), do: old

  # --- Broadcast dispatch ---

  defp broadcast_change(%Event.FileIndexed{path: path}, seq, ctx, locations),
    do: broadcast_file(path, ctx.file_id, :indexed, seq, locations)

  defp broadcast_change(%Event.FileModified{path: path}, seq, ctx, locations),
    do: broadcast_file(path, ctx.file_id, :modified, seq, locations)

  defp broadcast_change(%Event.FileDeleted{path: path}, seq, ctx, locations),
    do: broadcast_file(path, ctx.file_id, :deleted, seq, locations)

  defp broadcast_change(
         %Event.FileMoved{from_path: from, to_path: to},
         seq,
         ctx,
         locations
       ) do
    origin_id = Atlas.Library.resolve_location_id(from, locations)
    dest_id = Atlas.Library.resolve_location_id(to, locations)

    cond do
      origin_id == dest_id and dest_id != nil ->
        emit_file_change(dest_id, %{
          path: to,
          file_id: ctx.file_id,
          kind: :moved_in,
          seq: seq,
          location_id: dest_id
        })

      true ->
        if origin_id do
          emit_file_change(origin_id, %{
            path: from,
            file_id: ctx.file_id,
            kind: :moved_out,
            seq: seq,
            location_id: origin_id
          })
        end

        if dest_id do
          emit_file_change(dest_id, %{
            path: to,
            file_id: ctx.file_id,
            kind: :moved_in,
            seq: seq,
            location_id: dest_id
          })
        end
    end

    :ok
  end

  defp broadcast_change(%Event.LocationAdded{} = e, _seq, ctx, _) do
    emit_location_change(:added, ctx.location_id, e.path)
  end

  defp broadcast_change(%Event.LocationRemoved{} = e, _seq, ctx, _) do
    emit_location_change(:removed, ctx.location_id, e.path)
  end

  defp broadcast_change(%Event.LocationScanStarted{} = e, _seq, ctx, _) do
    emit_location_change(:scan_started, ctx.location_id, e.path)
  end

  defp broadcast_change(%Event.LocationScanCompleted{} = e, _seq, ctx, _) do
    emit_location_change(:scan_completed, ctx.location_id, e.path)
  end

  defp broadcast_change(%Event.LocationIgnoreSet{} = e, _seq, ctx, _) do
    emit_location_change(:ignore_set, ctx.location_id, e.path)
  end

  defp broadcast_change(%Event.LocationModeSet{} = e, _seq, ctx, _) do
    emit_location_change(:mode_set, ctx.location_id, e.path)
  end

  defp broadcast_change(%Event.LocationScanProgress{} = e, _seq, ctx, _) do
    # Scan progress goes to its own topic — consumers opt in separately
    # from the general file-list subscribers.
    if ctx.location_id do
      emit(
        Atlas.Library.location_scan_topic(ctx.location_id),
        {:scan_progress,
         %{
           location_id: ctx.location_id,
           files_done: e.files_done,
           bytes_done: e.bytes_done,
           current_path: e.current_path,
           total_files: e.total_files,
           total_bytes: e.total_bytes
         }}
      )
    end

    :ok
  end

  defp broadcast_file(path, file_id, kind, seq, locations) do
    case Atlas.Library.resolve_location_id(path, locations) do
      nil ->
        :ok

      location_id ->
        emit_file_change(location_id, %{
          path: path,
          file_id: file_id,
          kind: kind,
          seq: seq,
          location_id: location_id
        })
    end
  end

  defp emit_file_change(location_id, payload) do
    started = System.monotonic_time(:microsecond)

    :ok =
      Phoenix.PubSub.broadcast(
        Atlas.PubSub,
        Atlas.Library.location_topic(location_id),
        {:file_changed, payload}
      )

    :telemetry.execute(
      [:atlas, :projection, :broadcast],
      %{latency_us: System.monotonic_time(:microsecond) - started},
      %{kind: payload.kind, topic: :file}
    )

    :ok
  end

  defp emit_location_change(kind, location_id, path) do
    started = System.monotonic_time(:microsecond)

    :ok =
      Phoenix.PubSub.broadcast(
        Atlas.PubSub,
        Atlas.Library.locations_topic(),
        {:location_changed,
         %{kind: kind, location_id: location_id, path: path}}
      )

    :telemetry.execute(
      [:atlas, :projection, :broadcast],
      %{latency_us: System.monotonic_time(:microsecond) - started},
      %{kind: kind, topic: :location}
    )

    :ok
  end

  defp emit(topic, message) do
    :ok = Phoenix.PubSub.broadcast(Atlas.PubSub, topic, message)
    :ok
  end

  # --- Projection state helpers ---

  defp load_last_applied_seq do
    case Repo.get(ProjectionState, 1) do
      %ProjectionState{last_applied_seq: seq} -> seq
      nil -> 0
    end
  rescue
    _ -> 0
  end

  defp save_last_applied_seq(seq) do
    %ProjectionState{id: 1, last_applied_seq: seq}
    |> Repo.insert!(on_conflict: {:replace, [:last_applied_seq]}, conflict_target: :id)

    :ok
  end

  defp drop_and_remigrate do
    migrations = Application.app_dir(:atlas, "priv/repo/migrations")
    Ecto.Migrator.run(Repo, migrations, :down, all: true)
    Ecto.Migrator.run(Repo, migrations, :up, all: true)
    :ok
  end
end
