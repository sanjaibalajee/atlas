defmodule Atlas.Schemas.File do
  @moduledoc """
  Projection row: one per indexed file path.

  `deleted_at_us` nil means the file is live; non-nil means a
  `FileDeleted` event was applied and the row is a tombstone.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "files" do
    field :path, :string
    field :size, :integer
    field :mtime_us, :integer
    field :root_hash, :binary
    field :deleted_at_us, :integer
    field :indexed_at_us, :integer

    has_many :file_chunks, Atlas.Schemas.FileChunk, preload_order: [asc: :ordinal]

    timestamps(type: :utc_datetime_usec)
  end

  @required [:path, :size, :mtime_us, :root_hash, :indexed_at_us]
  @optional [:deleted_at_us]

  @spec upsert_changeset(t(), map()) :: Ecto.Changeset.t()
  def upsert_changeset(file, attrs) do
    file
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> unique_constraint(:path)
  end
end
