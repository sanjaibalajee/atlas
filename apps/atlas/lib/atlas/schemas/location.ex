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
    # SQLite has no array type; we store JSON text and cast here.
    field :ignore_patterns, Atlas.Schemas.JsonList, default: []

    # "shallow" (sampled hash, no CAS) or "content" (full chunking + CAS).
    # Default matches the migration default and `Atlas.Locations.add/2`
    # default mode so behaviour stays consistent.
    field :index_mode, :string, default: "shallow"

    timestamps(type: :utc_datetime_usec)
  end

  @required [:path, :added_at_us]
  @optional [
    :removed_at_us,
    :scan_started_at_us,
    :last_scanned_at_us,
    :ignore_patterns,
    :index_mode
  ]

  @valid_index_modes ~w(shallow content)

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(location, attrs) do
    location
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:index_mode, @valid_index_modes)
    |> unique_constraint(:path)
  end

  @doc "Set of allowed `index_mode` values."
  @spec valid_index_modes() :: [String.t()]
  def valid_index_modes, do: @valid_index_modes
end
