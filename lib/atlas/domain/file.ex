defmodule Atlas.Domain.File do
  @moduledoc """
  A file as Atlas sees it: a path plus the ordered list of chunks that
  make it up, plus a Merkle-like root hash that uniquely identifies the
  content regardless of path.
  """

  @enforce_keys [:path, :size, :mtime_us, :chunks, :root_hash]
  defstruct [:path, :size, :mtime_us, :chunks, :root_hash]

  @type t :: %__MODULE__{
          path: String.t(),
          size: non_neg_integer(),
          mtime_us: integer(),
          chunks: [Atlas.Domain.Chunk.t()],
          root_hash: Atlas.Domain.Hash.t()
        }
end
