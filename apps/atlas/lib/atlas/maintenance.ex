defmodule Atlas.Maintenance do
  @moduledoc """
  Background housekeeping for the local Atlas instance.

  Handles two jobs on independent intervals:

    * **Projection WAL checkpoint** — periodically runs
      `PRAGMA wal_checkpoint(PASSIVE)` against `Atlas.Repo` so the
      `projection.db-wal` file doesn't grow unbounded while the projector
      keeps a reader connection open. (The log db is handled directly by
      `Atlas.Log.SqliteLog`, which owns its own raw Exqlite connection.)

    * **Orphan chunk sweep** — periodically calls `Atlas.GC.sweep/1` so
      chunk bytes left behind by tombstoned locations, re-indexed files,
      and aborted scans are reclaimed without the user needing to run
      `mix atlas.gc` by hand.

  Intervals are intentionally long-defaults: these jobs are for the
  steady state, not a hot path. Both can be overridden at start for tests.
  """

  use GenServer
  require Logger

  alias Atlas.GC

  @default_checkpoint_interval_ms 60_000
  @default_gc_interval_ms 10 * 60_000

  # --- API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Trigger the checkpoint immediately (used in tests)."
  @spec checkpoint_now() :: :ok
  def checkpoint_now, do: GenServer.call(__MODULE__, :checkpoint_now)

  @doc "Trigger a GC sweep immediately. Returns the sweep result."
  @spec gc_now() :: GC.result()
  def gc_now, do: GenServer.call(__MODULE__, :gc_now, 60_000)

  # --- Lifecycle ---

  @impl true
  def init(opts) do
    state = %{
      checkpoint_interval_ms:
        Keyword.get(opts, :checkpoint_interval_ms, @default_checkpoint_interval_ms),
      gc_interval_ms: Keyword.get(opts, :gc_interval_ms, @default_gc_interval_ms),
      gc_enabled?: Keyword.get(opts, :gc_enabled?, true)
    }

    schedule(:checkpoint, state.checkpoint_interval_ms)
    if state.gc_enabled?, do: schedule(:gc, state.gc_interval_ms)

    {:ok, state}
  end

  @impl true
  def handle_info(:checkpoint, state) do
    run_checkpoint()
    schedule(:checkpoint, state.checkpoint_interval_ms)
    {:noreply, state}
  end

  def handle_info(:gc, state) do
    _ = run_gc()
    schedule(:gc, state.gc_interval_ms)
    {:noreply, state}
  end

  @impl true
  def handle_call(:checkpoint_now, _from, state) do
    run_checkpoint()
    {:reply, :ok, state}
  end

  def handle_call(:gc_now, _from, state) do
    {:reply, run_gc(), state}
  end

  # --- Private ---

  defp run_checkpoint do
    case Ecto.Adapters.SQL.query(Atlas.Repo, "PRAGMA wal_checkpoint(PASSIVE)", []) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning("maintenance: projection checkpoint failed: #{inspect(reason)}")
    end
  rescue
    # Repo might not be started (e.g., during test setup/teardown). Log and
    # move on — the next interval will try again.
    e ->
      Logger.debug("maintenance: checkpoint skipped: #{Exception.message(e)}")
      :skipped
  end

  defp run_gc do
    result = GC.sweep()

    if result.removed > 0 do
      Logger.info(
        "maintenance: swept #{result.removed} orphan chunk(s), " <>
          "reclaimed #{result.bytes_reclaimed} bytes"
      )
    end

    result
  rescue
    e ->
      Logger.warning("maintenance: gc failed: #{Exception.message(e)}")
      %{scanned: 0, removed: 0, bytes_reclaimed: 0}
  end

  defp schedule(msg, interval_ms),
    do: Process.send_after(self(), msg, interval_ms)
end
