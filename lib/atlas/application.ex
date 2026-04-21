defmodule Atlas.Application do
  @moduledoc """
  The top-level OTP application.

  Supervision tree:

      Atlas.Supervisor (one_for_one)
      ├── Atlas.Repo                       (projection DB)
      ├── Atlas.Store.Supervisor           (CAS backends)
      ├── Atlas.Log.Supervisor             (event log writer)
      ├── Atlas.Projection.Supervisor      (event → Ecto projector)
      └── Atlas.Indexer.Supervisor         (dynamic per-run indexers)

  The order matters: the projector depends on the log; the indexer depends
  on both the log and the store; everything depends on the repo.
  """

  use Application

  @impl true
  def start(_type, _args) do
    ensure_data_dirs!()

    children = [
      Atlas.Repo,
      # Log-event pub/sub (M1.5). Must start before the projector so the
      # projector can subscribe on init.
      Atlas.Log.Notifier,
      # Registry backing `Atlas.Watcher` name lookups (M1.6).
      {Registry, keys: :unique, name: Atlas.Watcher.Registry},
      Atlas.Store.Supervisor,
      Atlas.Log.Supervisor,
      Atlas.Projection.Supervisor,
      Atlas.Watcher.Supervisor,
      Atlas.Indexer.Supervisor
    ]

    opts = [strategy: :one_for_one, name: Atlas.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp ensure_data_dirs! do
    File.mkdir_p!(Atlas.data_dir())
    File.mkdir_p!(Atlas.store_dir())
  end
end
