defmodule Atlas.Schemas.ProjectionState do
  @moduledoc """
  Singleton row tracking the highest event-log sequence number that the
  projector has applied. The projector writes this in the same transaction
  as the event's effects, so projection and bookkeeping can never diverge.

  Always has id = 1; attempts to insert any other id are blocked at the
  database level via a CHECK constraint in the migration.
  """

  use Ecto.Schema

  @primary_key {:id, :integer, autogenerate: false}
  schema "projection_state" do
    field :last_applied_seq, :integer, default: 0
  end
end
