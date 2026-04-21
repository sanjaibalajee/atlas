defmodule Atlas.Projection.Projector do
  @moduledoc """
  Consumes events from `Atlas.Log` and maintains the read model in
  `Atlas.Repo`.

  On boot we read `projection_state.last_applied_seq` and catch up. After
  that, we poll the log at a fixed interval — Phase 0 keeps this simple;
  Phase 1 will replace polling with a pub/sub notification from the log
  writer.

  `rebuild/0` drops the projection tables, re-runs migrations, and
  replays the entire log. This is the test that proves the log is the
  only source of truth.
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
    {:ok, %{last_seq: last_seq}}
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
    new_state = catch_up(%{state | last_seq: 0}, :infinity)
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
          :ok = apply_and_advance(event, seq)
          {:cont, %{acc | last_seq: seq}}
      end
    end)
  end

  defp apply_and_advance(event, seq) do
    Repo.transaction(fn ->
      :ok = apply_event(event)
      :ok = save_last_applied_seq(seq)
    end)

    :ok
  end

  # --- Event handlers ---

  # FileIndexed and FileModified have identical projection semantics —
  # both upsert the file row by path and replace its chunk mappings.
  # They remain distinct event types so downstream consumers (UI,
  # notifications, audit) can tell "new" from "changed" without re-deriving.
  defp apply_event(%Event.FileIndexed{} = e), do: upsert_file_with_chunks(e)
  defp apply_event(%Event.FileModified{} = e), do: upsert_file_with_chunks(e)

  defp apply_event(%Event.FileMoved{from_path: from, to_path: to}) do
    Repo.update_all(
      from(f in FileRow, where: f.path == ^from),
      set: [path: to]
    )

    :ok
  end

  defp apply_event(%Event.FileDeleted{path: path, at: at}) do
    case Repo.get_by(FileRow, path: path) do
      nil ->
        :ok

      %FileRow{id: id} = file ->
        # Capture referenced chunks before removing the file_chunks rows
        # so we know whose ref_counts to recompute.
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
        :ok
    end
  end

  defp apply_event(%Event.LocationAdded{path: path, at: at}) do
    %Location{}
    |> Location.changeset(%{path: path, added_at_us: at, removed_at_us: nil})
    |> Repo.insert!(
      on_conflict: {:replace_all_except, [:id, :inserted_at]},
      conflict_target: :path
    )

    :ok
  end

  defp apply_event(%Event.LocationRemoved{path: path, at: at}) do
    Repo.update_all(
      from(l in Location, where: l.path == ^path),
      set: [removed_at_us: at]
    )

    :ok
  end

  defp apply_event(%Event.LocationScanStarted{path: path, at: at}) do
    Repo.update_all(
      from(l in Location, where: l.path == ^path),
      set: [scan_started_at_us: at]
    )

    :ok
  end

  defp apply_event(%Event.LocationScanCompleted{path: path, at: at}) do
    Repo.update_all(
      from(l in Location, where: l.path == ^path),
      set: [last_scanned_at_us: at]
    )

    :ok
  end

  defp upsert_file_with_chunks(e) do
    now = System.os_time(:microsecond)

    # Capture the existing file's chunks (if any) BEFORE mutating, so we
    # know whose ref_counts need recomputing afterwards.
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

    # Blow away old chunk mappings for this file; rewrite in order.
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

    # Recompute ref_counts for everything that was touched. A hash that
    # vanished from `old_hashes` drops to the new count (possibly 0 →
    # orphan). A new hash grows by 1. Dedup+aggregate lets us do this in
    # two queries regardless of chunk count.
    recompute_ref_counts(old_hashes ++ Enum.map(e.chunks, & &1.hash))
    :ok
  end

  # Recompute `chunks.ref_count` for each affected hash by counting the
  # file_chunks rows that currently reference it.
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

  # --- Projection state helpers ---

  defp load_last_applied_seq do
    case Repo.get(ProjectionState, 1) do
      %ProjectionState{last_applied_seq: seq} -> seq
      nil -> 0
    end
  rescue
    # Table may not exist yet if migrations haven't run.
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
