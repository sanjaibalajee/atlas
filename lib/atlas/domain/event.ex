defmodule Atlas.Domain.Event do
  @moduledoc """
  Events are the only source of truth. Every state change in Atlas is an
  event appended to `Atlas.Log`. Projections are derived from the log and
  can be rebuilt at any time.

  Each event is a struct with:

    * `v`   — schema version (start at 1; bump on breaking shape changes)
    * `at`  — microseconds since the UNIX epoch, monotonic per process

  Add fields freely; never reorder or retype existing ones without
  bumping `v` and writing an upcaster in `Atlas.Projection.Projector`.
  """

  alias Atlas.Domain.Chunk

  defmodule FileIndexed do
    @moduledoc "A file was fully indexed: chunked, hashed, and stored."
    @enforce_keys [:v, :at, :path, :size, :mtime_us, :root_hash, :chunks]
    defstruct [:v, :at, :path, :size, :mtime_us, :root_hash, :chunks]

    @type t :: %__MODULE__{
            v: pos_integer(),
            at: integer(),
            path: String.t(),
            size: non_neg_integer(),
            mtime_us: integer(),
            root_hash: Atlas.Domain.Hash.t(),
            chunks: [Chunk.t()]
          }
  end

  defmodule FileModified do
    @moduledoc """
    A previously indexed file's content changed — new chunks replace old.

    Shape mirrors `FileIndexed` exactly so projectors that don't care about
    the distinction can handle both with one clause; consumers that do
    (notifications, UI, audit) can discriminate by event type.
    """
    @enforce_keys [:v, :at, :path, :size, :mtime_us, :root_hash, :chunks]
    defstruct [:v, :at, :path, :size, :mtime_us, :root_hash, :chunks]

    @type t :: %__MODULE__{
            v: pos_integer(),
            at: integer(),
            path: String.t(),
            size: non_neg_integer(),
            mtime_us: integer(),
            root_hash: Atlas.Domain.Hash.t(),
            chunks: [Chunk.t()]
          }
  end

  defmodule FileMoved do
    @moduledoc """
    A file changed path without changing content. Same root hash, same
    chunks; only the path identifier moves. No re-chunking required.
    Covers renames, directory relocations, and drag-and-drop within a
    single volume.
    """
    @enforce_keys [:v, :at, :from_path, :to_path]
    defstruct [:v, :at, :from_path, :to_path]

    @type t :: %__MODULE__{
            v: pos_integer(),
            at: integer(),
            from_path: String.t(),
            to_path: String.t()
          }
  end

  defmodule FileDeleted do
    @moduledoc "A previously indexed file is gone from the source filesystem."
    @enforce_keys [:v, :at, :path]
    defstruct [:v, :at, :path]

    @type t :: %__MODULE__{
            v: pos_integer(),
            at: integer(),
            path: String.t()
          }
  end

  defmodule LocationAdded do
    @moduledoc """
    A directory was added to Atlas as a watched location. Indexing and
    filesystem watching begin from this event; everything Atlas does is
    scoped to one or more locations.
    """
    @enforce_keys [:v, :at, :path]
    defstruct [:v, :at, :path]

    @type t :: %__MODULE__{
            v: pos_integer(),
            at: integer(),
            path: String.t()
          }
  end

  defmodule LocationRemoved do
    @moduledoc """
    A previously watched location is no longer watched. Indexed files
    under the location are tombstoned separately via `FileDeleted`; the
    location itself becomes a tombstone.
    """
    @enforce_keys [:v, :at, :path]
    defstruct [:v, :at, :path]

    @type t :: %__MODULE__{
            v: pos_integer(),
            at: integer(),
            path: String.t()
          }
  end

  defmodule LocationScanStarted do
    @moduledoc "An indexing scan began for a location."
    @enforce_keys [:v, :at, :path]
    defstruct [:v, :at, :path]

    @type t :: %__MODULE__{
            v: pos_integer(),
            at: integer(),
            path: String.t()
          }
  end

  defmodule LocationScanCompleted do
    @moduledoc "An indexing scan completed for a location (successfully)."
    @enforce_keys [:v, :at, :path, :files, :bytes, :duration_us]
    defstruct [:v, :at, :path, :files, :bytes, :duration_us]

    @type t :: %__MODULE__{
            v: pos_integer(),
            at: integer(),
            path: String.t(),
            files: non_neg_integer(),
            bytes: non_neg_integer(),
            duration_us: non_neg_integer()
          }
  end

  @type t ::
          FileIndexed.t()
          | FileModified.t()
          | FileMoved.t()
          | FileDeleted.t()
          | LocationAdded.t()
          | LocationRemoved.t()
          | LocationScanStarted.t()
          | LocationScanCompleted.t()

  @doc "Current wall-clock timestamp in microseconds."
  @spec now_us() :: integer()
  def now_us, do: System.os_time(:microsecond)
end
