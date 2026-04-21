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

  defmodule LocationScanProgress do
    @moduledoc """
    Intermediate progress emitted during a long scan. Consumers (LiveView
    progress bars, metrics) read these; the projector ignores them beyond
    a counter for observability. `total_files` / `total_bytes` are
    best-effort estimates — `nil` when not yet known (pre-walk phase).
    """
    @enforce_keys [:v, :at, :path, :files_done, :bytes_done, :current_path]
    defstruct [
      :v,
      :at,
      :path,
      :files_done,
      :bytes_done,
      :current_path,
      :total_files,
      :total_bytes
    ]

    @type t :: %__MODULE__{
            v: pos_integer(),
            at: integer(),
            path: String.t(),
            files_done: non_neg_integer(),
            bytes_done: non_neg_integer(),
            current_path: String.t(),
            total_files: non_neg_integer() | nil,
            total_bytes: non_neg_integer() | nil
          }
  end

  defmodule LocationIgnoreSet do
    @moduledoc """
    Replaces the ignore-pattern list for a location. Patterns are glob-style
    (`.git`, `node_modules`, `*.lock`, `**/target`); applied by the walker
    and the watcher before any `File.stat`, so ignored subtrees never
    reach the indexer. Replace-semantics (not append) — pass the full
    desired list each time.
    """
    @enforce_keys [:v, :at, :path, :patterns]
    defstruct [:v, :at, :path, :patterns]

    @type t :: %__MODULE__{
            v: pos_integer(),
            at: integer(),
            path: String.t(),
            patterns: [String.t()]
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
          | LocationScanProgress.t()
          | LocationIgnoreSet.t()

  @doc "Current wall-clock timestamp in microseconds."
  @spec now_us() :: integer()
  def now_us, do: System.os_time(:microsecond)
end
