defmodule Atlas.Application do
  @moduledoc """
  The top-level OTP application.

  Supervision tree:

      Atlas.Supervisor (one_for_one)
      ├── Atlas.Repo                       (projection DB)
      ├── Atlas.Log.Notifier               (internal Registry pub/sub)
      ├── Phoenix.PubSub (Atlas.PubSub)    (fan-out to LiveView subscribers)
      ├── Atlas.Watcher.Registry           (per-location Watcher name lookup)
      ├── Atlas.Store.Supervisor           (CAS backends)
      ├── Atlas.Log.Supervisor             (event log writer)
      ├── Atlas.Projection.Supervisor      (event → Ecto projector)
      ├── Atlas.Watcher.Supervisor         (per-location file watchers)
      ├── Atlas.Watcher.Boot               (one-shot: revive watchers for active locations)
      ├── Atlas.Indexer.Supervisor         (dynamic per-run indexers)
      └── Atlas.Maintenance                (WAL checkpoint + orphan GC)

  The order matters: the projector depends on the log; the indexer depends
  on both the log and the store; everything depends on the repo. PubSub
  starts before the projector so rebroadcasts on apply never race an
  uninitialised pubsub.
  """

  use Application

  @impl true
  def start(_type, _args) do
    ensure_data_dirs!()

    children = [
      Atlas.Repo,
      Atlas.Log.Notifier,
      {Phoenix.PubSub, name: Atlas.PubSub},
      {Registry, keys: :unique, name: Atlas.Watcher.Registry},
      Atlas.Store.Supervisor,
      Atlas.Log.Supervisor,
      Atlas.Projection.Supervisor,
      Atlas.Watcher.Supervisor,
      Atlas.Watcher.Boot,
      Atlas.Indexer.Supervisor,
      Atlas.Maintenance
    ]

    opts = [strategy: :one_for_one, name: Atlas.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp ensure_data_dirs! do
    File.mkdir_p!(Atlas.data_dir())
    File.mkdir_p!(Atlas.store_dir())
  end
end
