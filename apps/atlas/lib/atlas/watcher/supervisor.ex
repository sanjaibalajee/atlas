defmodule Atlas.Watcher.Supervisor do
  @moduledoc """
  `DynamicSupervisor` for `Atlas.Watcher` processes — one child per
  watched location. Looked up via `Atlas.Watcher.Registry`.
  """

  use DynamicSupervisor

  def start_link(_opts),
    do: DynamicSupervisor.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok), do: DynamicSupervisor.init(strategy: :one_for_one)

  @doc """
  Start a watcher on `path`. Returns `{:ok, pid}`. Idempotent — calling
  twice for the same path returns the existing watcher's pid.

  `patterns` (optional) is the location's current ignore-pattern list,
  passed in by the caller. Compiled once on init; filters OS events
  before the indexer sees them. Passing patterns here (rather than
  having the watcher query the projection itself) keeps DB access off
  the watcher's init path — important for tests where the watcher
  process isn't in the Ecto sandbox's allow list.
  """
  @spec start_watching(Path.t(), [String.t()] | nil, :shallow | :content) ::
          {:ok, pid()} | {:error, term()}
  def start_watching(path, patterns \\ nil, mode \\ :shallow) do
    path = Path.expand(path)

    case DynamicSupervisor.start_child(__MODULE__, {Atlas.Watcher, {path, patterns, mode}}) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      other -> other
    end
  end

  @doc "Stop the watcher for `path`, if any."
  @spec stop_watching(Path.t()) :: :ok | {:error, :not_found}
  def stop_watching(path) do
    case Registry.lookup(Atlas.Watcher.Registry, Path.expand(path)) do
      [{pid, _}] ->
        DynamicSupervisor.terminate_child(__MODULE__, pid)
        :ok

      [] ->
        {:error, :not_found}
    end
  end

  @doc "List paths currently under watch."
  @spec watching() :: [String.t()]
  def watching do
    Atlas.Watcher.Registry
    |> Registry.select([{{:"$1", :_, :_}, [], [:"$1"]}])
    |> Enum.sort()
  end
end
