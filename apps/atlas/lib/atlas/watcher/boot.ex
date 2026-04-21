defmodule Atlas.Watcher.Boot do
  @moduledoc """
  One-shot supervisor child that revives per-location watchers after the
  app boots. Without this, only locations added during the current BEAM
  lifetime would ever be watched — restarting the server would silently
  stop tracking everything `Locations.add/1` previously set up.

  Placed in the supervision tree *after* `Atlas.Watcher.Supervisor` so the
  dynamic supervisor exists by the time we ask it to spawn children. Uses
  `restart: :transient` so a successful run is not retried; a crash will
  still bring the tree down loudly.
  """

  require Logger

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :transient
    }
  end

  def start_link(_opts) do
    Task.start_link(&ensure_watchers/0)
  end

  @doc """
  Start watchers for every active (non-tombstoned) location in the
  projection. Idempotent — `start_watching/1` returns the existing pid
  if a watcher for that path is already running.
  """
  @spec ensure_watchers() :: :ok
  def ensure_watchers do
    Atlas.Library.list_locations()
    |> Enum.each(fn loc ->
      case Atlas.Watcher.Supervisor.start_watching(loc.path) do
        {:ok, _pid} ->
          :ok

        {:error, reason} ->
          Logger.warning("watcher.boot: failed to start watcher for #{loc.path}: #{inspect(reason)}")
      end
    end)

    :ok
  end
end
