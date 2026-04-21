defmodule Atlas.Indexer.Supervisor do
  @moduledoc """
  DynamicSupervisor for per-run indexer processes.

  Phase 0 does not yet spawn children — `Atlas.Indexer.index/1` runs
  synchronously in the caller. The supervisor is in place so that Phase 1
  can launch indexers as checkpointed, restartable jobs without changing
  the public API.
  """

  use DynamicSupervisor

  def start_link(opts), do: DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts), do: DynamicSupervisor.init(strategy: :one_for_one)
end
