defmodule Atlas.Store.Supervisor do
  @moduledoc """
  Supervises store backends. Currently one child: the local-FS store.
  Phase 5 will add cloud backends (S3, GDrive) as siblings.
  """

  use Supervisor

  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    children = [Atlas.Store.LocalFs]
    Supervisor.init(children, strategy: :one_for_one)
  end
end
