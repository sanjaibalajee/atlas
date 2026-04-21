defmodule Atlas.Log.SqliteLog do
  @moduledoc """
  SQLite-backed event log.

  Uses a dedicated SQLite database — not the projection repo — so that
  "truth" and "cache" can never collide. Appends are serialized through
  this GenServer; reads open a fresh connection so they never block the
  writer (WAL mode gives them a consistent snapshot).

  Payloads are serialized with `:erlang.term_to_binary/2` for Phase 0.
  This round-trips nested structs (like the list of `%Atlas.Domain.Chunk{}`
  inside a `FileIndexed` event) without an explicit schema. When we add
  cross-language consumers in later phases we will move to MessagePack
  with an explicit discriminator.
  """

  @behaviour Atlas.Log

  use GenServer
  alias Exqlite.Sqlite3
  require Logger

  @table "events"

  # --- Atlas.Log callbacks ---

  @impl Atlas.Log
  def append(event), do: GenServer.call(__MODULE__, {:append, event})

  @impl Atlas.Log
  def stream(from \\ 0), do: build_stream(from)

  @impl Atlas.Log
  def head, do: GenServer.call(__MODULE__, :head)

  # --- Lifecycle ---

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  # How often to checkpoint (fold the WAL into the main db and truncate the
  # WAL file). Without this the log WAL grows unbounded because the
  # SqliteLog GenServer holds its writer connection open forever, defeating
  # SQLite's default autocheckpoint-on-close. 60s balances IO cost against
  # disk growth for a typical watcher firing a handful of events per second.
  @checkpoint_interval_ms 60_000

  @impl GenServer
  def init(_opts) do
    path = Atlas.log_db_path()
    File.mkdir_p!(Path.dirname(path))

    {:ok, db} = Sqlite3.open(path)
    :ok = Sqlite3.execute(db, "PRAGMA journal_mode = WAL")
    :ok = Sqlite3.execute(db, "PRAGMA synchronous = NORMAL")
    # Autocheckpoint threshold (pages; default is 1000 ≈ 4 MB). Paired with
    # the periodic :checkpoint message below for belt-and-braces coverage.
    :ok = Sqlite3.execute(db, "PRAGMA wal_autocheckpoint = 1000")
    :ok = init_schema(db)

    schedule_checkpoint()
    Logger.debug("log.sqlite ready at #{path}")
    {:ok, %{db: db, path: path}}
  end

  @impl GenServer
  def terminate(_reason, %{db: db}) do
    # Truncate the WAL on orderly shutdown so the on-disk footprint stays
    # small after `mix phx.server` exits. TRUNCATE mode blocks until all
    # readers drain and resets the WAL file to zero.
    _ = Sqlite3.execute(db, "PRAGMA wal_checkpoint(TRUNCATE)")
    Sqlite3.close(db)
  end

  @impl GenServer
  def handle_info(:checkpoint, %{db: db} = state) do
    case Sqlite3.execute(db, "PRAGMA wal_checkpoint(PASSIVE)") do
      :ok -> :ok
      other -> Logger.warning("log.sqlite: checkpoint failed: #{inspect(other)}")
    end

    schedule_checkpoint()
    {:noreply, state}
  end

  defp schedule_checkpoint,
    do: Process.send_after(self(), :checkpoint, @checkpoint_interval_ms)

  @impl GenServer
  def handle_call({:append, event}, _from, %{db: db} = state) do
    enc = encode(event)

    {:ok, stmt} =
      Sqlite3.prepare(
        db,
        "INSERT INTO #{@table}(kind, at, v, payload) VALUES(?, ?, ?, ?)"
      )

    # Payload is wrapped in `{:blob, _}` so Exqlite binds it as a SQLite
    # BLOB rather than TEXT — STRICT mode rejects TEXT in a BLOB column.
    reply =
      with :ok <- Sqlite3.bind(stmt, [enc.kind, enc.at, enc.v, {:blob, enc.payload}]),
           :done <- Sqlite3.step(db, stmt) do
        {:ok, normalize_rowid(Sqlite3.last_insert_rowid(db))}
      else
        other -> {:error, other}
      end

    :ok = Sqlite3.release(db, stmt)

    # Notify subscribers after a successful commit so the projector
    # catches up without polling (M1.5).
    case reply do
      {:ok, seq} -> Atlas.Log.Notifier.broadcast(seq)
      _ -> :ok
    end

    {:reply, reply, state}
  end

  def handle_call(:head, _from, %{db: db} = state) do
    {:ok, stmt} = Sqlite3.prepare(db, "SELECT COALESCE(MAX(seq), 0) FROM #{@table}")
    {:row, [head]} = Sqlite3.step(db, stmt)
    :ok = Sqlite3.release(db, stmt)
    {:reply, head, state}
  end

  # --- Streaming read ---

  defp build_stream(from) do
    Stream.resource(
      fn ->
        {:ok, db} = Sqlite3.open(Atlas.log_db_path())
        # Readers are non-authoritative: WAL gives us a snapshot at open.
        :ok = Sqlite3.execute(db, "PRAGMA query_only = ON")

        {:ok, stmt} =
          Sqlite3.prepare(
            db,
            "SELECT seq, kind, at, v, payload FROM #{@table} " <>
              "WHERE seq > ? ORDER BY seq ASC"
          )

        :ok = Sqlite3.bind(stmt, [from])
        {db, stmt}
      end,
      fn {db, stmt} = acc ->
        case Sqlite3.step(db, stmt) do
          {:row, [seq, kind, at, v, payload]} ->
            {[{seq, decode(kind, at, v, payload)}], acc}

          :done ->
            {:halt, acc}
        end
      end,
      fn {db, stmt} ->
        Sqlite3.release(db, stmt)
        Sqlite3.close(db)
      end
    )
  end

  # --- Schema & codec ---

  defp init_schema(db) do
    Sqlite3.execute(db, """
      CREATE TABLE IF NOT EXISTS #{@table} (
        seq     INTEGER PRIMARY KEY AUTOINCREMENT,
        kind    TEXT    NOT NULL,
        at      INTEGER NOT NULL,
        v       INTEGER NOT NULL,
        payload BLOB    NOT NULL
      ) STRICT
    """)
  end

  defp encode(event) do
    %{
      kind: event_kind(event),
      at: event.at,
      v: event.v,
      payload: :erlang.term_to_binary(event, [:compressed])
    }
  end

  defp decode(_kind, _at, _v, payload), do: :erlang.binary_to_term(payload)

  # Exqlite 0.36 wraps `last_insert_rowid` in `{:ok, n}`; older versions
  # return `n` directly. Accept both.
  defp normalize_rowid({:ok, n}) when is_integer(n), do: n
  defp normalize_rowid(n) when is_integer(n), do: n

  defp event_kind(%Atlas.Domain.Event.FileIndexed{}), do: "file_indexed"
  defp event_kind(%Atlas.Domain.Event.FileModified{}), do: "file_modified"
  defp event_kind(%Atlas.Domain.Event.FileMoved{}), do: "file_moved"
  defp event_kind(%Atlas.Domain.Event.FileDeleted{}), do: "file_deleted"
  defp event_kind(%Atlas.Domain.Event.LocationAdded{}), do: "location_added"
  defp event_kind(%Atlas.Domain.Event.LocationRemoved{}), do: "location_removed"
  defp event_kind(%Atlas.Domain.Event.LocationScanStarted{}), do: "location_scan_started"
  defp event_kind(%Atlas.Domain.Event.LocationScanCompleted{}), do: "location_scan_completed"
  defp event_kind(%Atlas.Domain.Event.LocationScanProgress{}), do: "location_scan_progress"
  defp event_kind(%Atlas.Domain.Event.LocationIgnoreSet{}), do: "location_ignore_set"
  defp event_kind(%Atlas.Domain.Event.LocationModeSet{}), do: "location_mode_set"
end
