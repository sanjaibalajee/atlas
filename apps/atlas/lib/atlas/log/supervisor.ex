defmodule Atlas.Log.Supervisor do
  @moduledoc "Supervises the event log writer."

  use Supervisor

  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    children = [Atlas.Log.SqliteLog]
    Supervisor.init(children, strategy: :one_for_one)
  end
end
