defmodule Atlas.Schemas.FileChunk do
  @moduledoc """
  Projection row: one per (file, chunk) pair, ordered by `ordinal`.

  `chunk_hash` is duplicated here (it's also the primary key of `chunks`)
  so that path-ordered reconstruction of a file does not require a join
  on the chunks table.
  """

  use Ecto.Schema

  @primary_key false
  schema "file_chunks" do
    field :ordinal, :integer, primary_key: true
    field :offset, :integer
    field :length, :integer
    field :chunk_hash, :binary

    belongs_to :file, Atlas.Schemas.File, primary_key: true
  end
end
