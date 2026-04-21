defmodule Atlas.Schemas.Chunk do
  @moduledoc """
  Projection row: one per unique chunk hash.

  `ref_count` will track the number of `file_chunks` rows pointing at this
  chunk once we wire up garbage collection in Phase 1. For Phase 0 we just
  insert rows and leave ref-counting for later.
  """

  use Ecto.Schema

  @primary_key {:hash, :binary, autogenerate: false}
  schema "chunks" do
    field :length, :integer
    field :ref_count, :integer, default: 0

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
