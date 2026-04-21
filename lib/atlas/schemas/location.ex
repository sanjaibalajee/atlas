defmodule Atlas.Schemas.Location do
  @moduledoc """
  Projection row for a watched directory. One per path.

  A non-nil `removed_at_us` is a tombstone — the location is no longer
  watched, but kept in the table so past events can still be interpreted
  against it.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "locations" do
    field :path, :string
    field :added_at_us, :integer
    field :removed_at_us, :integer
    field :scan_started_at_us, :integer
    field :last_scanned_at_us, :integer

    timestamps(type: :utc_datetime_usec)
  end

  @required [:path, :added_at_us]
  @optional [:removed_at_us, :scan_started_at_us, :last_scanned_at_us]

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(location, attrs) do
    location
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> unique_constraint(:path)
  end
end
