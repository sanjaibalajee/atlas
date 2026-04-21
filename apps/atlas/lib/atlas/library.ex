defmodule Atlas.Library do
  @moduledoc """
  Read-path seam between the Atlas kernel and any UI. Every LiveView (and
  any future API) consumes the projection through this module rather than
  touching `Atlas.Repo` directly — that lets us tune queries, add caching,
  or swap storage without hunting through templates.

  Also owns the canonical names for `Phoenix.PubSub` topics used by the
  projector's broadcast seam. Call sites should never hard-code topic
  strings.

  Pagination is **keyset** (cursor-based): given a sort column and an
  optional `:after` cursor, the next page is defined by
  `(sort_key, id) > cursor` (or `<` for descending). This keeps paging
  stable under concurrent inserts and avoids the `OFFSET N` tax on large
  locations. The tie-breaker on `id` guarantees a total ordering even
  when many rows share the same `sort_key` value.
  """

  import Ecto.Query

  alias Atlas.Repo
  alias Atlas.Schemas.{FileChunk, Location}
  alias Atlas.Schemas.File, as: FileRow

  # --- PubSub topics ---

  @doc "Sidebar channel — Location added/removed/scan events."
  @spec locations_topic() :: String.t()
  def locations_topic, do: "locations"

  @doc "Per-location file change channel — :indexed | :modified | :deleted | :moved_in | :moved_out."
  @spec location_topic(integer()) :: String.t()
  def location_topic(location_id) when is_integer(location_id),
    do: "location:#{location_id}"

  @doc "Per-location scan-progress channel (separate so general file subscribers skip it)."
  @spec location_scan_topic(integer()) :: String.t()
  def location_scan_topic(location_id) when is_integer(location_id),
    do: "location:#{location_id}:scan"

  # --- Locations ---

  @doc "Active locations (not tombstoned), ordered by path."
  @spec list_locations() :: [Location.t()]
  def list_locations do
    Repo.all(
      from l in Location,
        where: is_nil(l.removed_at_us),
        order_by: l.path
    )
  end

  @doc """
  Resolve a file path to its owning location id using longest-prefix match.

  `locations` is a list of maps `%{id, path}` (typically the projector's
  in-memory cache). Returns `nil` when no active location owns the path.
  """
  @spec resolve_location_id(String.t(), [%{id: integer(), path: String.t()}]) ::
          integer() | nil
  def resolve_location_id(path, locations) do
    locations
    |> Enum.filter(&prefix_match?(path, &1.path))
    |> Enum.max_by(&String.length(&1.path), fn -> nil end)
    |> case do
      nil -> nil
      loc -> loc.id
    end
  end

  defp prefix_match?(path, prefix) do
    path == prefix or String.starts_with?(path, prefix <> "/")
  end

  # --- Files ---

  @type sort_by :: :path | :size | :mtime_us | :indexed_at_us
  @type order :: :asc | :desc
  @type cursor :: {term(), integer()} | nil
  @type list_opts :: [
          limit: pos_integer(),
          sort_by: sort_by(),
          order: order(),
          after: cursor()
        ]

  @default_limit 100
  @max_limit 500

  @doc """
  Page a location's files, filtered to live rows (tombstones excluded).
  Returns `%{rows: [File.t()], cursor: cursor() | :eol}`.

  `:eol` means there are no more pages under the current sort. Otherwise
  pass `cursor` back as `:after` to fetch the next page.
  """
  @spec list_files(integer(), list_opts()) :: %{
          rows: [FileRow.t()],
          cursor: cursor() | :eol
        }
  def list_files(location_id, opts \\ []) when is_integer(location_id) do
    sort_by = Keyword.get(opts, :sort_by, :path)
    order = Keyword.get(opts, :order, :asc)
    limit = opts |> Keyword.get(:limit, @default_limit) |> min(@max_limit)
    cursor = Keyword.get(opts, :after)

    location = Repo.get(Location, location_id)

    if location == nil or location.removed_at_us != nil do
      %{rows: [], cursor: :eol}
    else
      prefix = trailing_slash(location.path)

      rows =
        FileRow
        |> where_under_location(location.path, prefix)
        |> where([f], is_nil(f.deleted_at_us))
        |> apply_cursor(sort_by, order, cursor)
        |> order_by_sort(sort_by, order)
        |> limit(^(limit + 1))
        |> Repo.all()

      {page, next_cursor} = finalize_page(rows, limit, sort_by)
      %{rows: page, cursor: next_cursor}
    end
  end

  @doc "Detail view — file row plus chunk count. `nil` if not found."
  @spec get_file(integer()) :: %{file: FileRow.t(), chunk_count: non_neg_integer()} | nil
  def get_file(file_id) when is_integer(file_id) do
    case Repo.get(FileRow, file_id) do
      nil ->
        nil

      file ->
        chunk_count =
          Repo.one(
            from fc in FileChunk,
              where: fc.file_id == ^file.id,
              select: count(fc.ordinal)
          ) || 0

        %{file: file, chunk_count: chunk_count}
    end
  end

  @doc """
  Aggregate stats for a location header. Only counts live (non-tombstoned)
  files. `watching?` reflects whether a watcher process is currently
  running for the location's path — the truthful signal for "changes
  update live in the UI", distinct from `last_scanned_at_us` which only
  advances on explicit full-directory scans.
  """
  @spec file_stats(integer()) :: %{
          files_count: non_neg_integer(),
          bytes_total: non_neg_integer(),
          last_scanned_at_us: integer() | nil,
          watching?: boolean()
        }
  def file_stats(location_id) when is_integer(location_id) do
    location = Repo.get(Location, location_id)

    if location == nil or location.removed_at_us != nil do
      %{files_count: 0, bytes_total: 0, last_scanned_at_us: nil, watching?: false}
    else
      prefix = trailing_slash(location.path)

      %{count: count, bytes: bytes} =
        FileRow
        |> where_under_location(location.path, prefix)
        |> where([f], is_nil(f.deleted_at_us))
        |> select([f], %{count: count(f.id), bytes: coalesce(sum(f.size), 0)})
        |> Repo.one()

      %{
        files_count: count,
        bytes_total: bytes,
        last_scanned_at_us: location.last_scanned_at_us,
        watching?: watching?(location.path)
      }
    end
  end

  defp watching?(path) do
    path in Atlas.Watcher.Supervisor.watching()
  end

  # --- Internals ---

  defp trailing_slash(path) do
    if String.ends_with?(path, "/"), do: path, else: path <> "/"
  end

  defp where_under_location(query, exact, prefix) do
    # SQLite LIKE treats `_` as a single-char wildcard (and `%` as multi).
    # Tmp dirs like `xsqfdpys73x0brsy_5qk3c480000gn` and any user path with
    # an underscore would otherwise leak rows from neighbouring locations
    # into the result. Escape both wildcards with `\` and declare the
    # escape char via `ESCAPE '\'` in the fragment.
    escaped = prefix |> escape_like() |> Kernel.<>("%")

    from f in query,
      where: f.path == ^exact or fragment("? LIKE ? ESCAPE '\\'", f.path, ^escaped)
  end

  defp escape_like(str) do
    str
    |> String.replace("\\", "\\\\")
    |> String.replace("_", "\\_")
    |> String.replace("%", "\\%")
  end

  # Sort + cursor predicates. The `<`/`>` direction follows `order`.
  #
  # For stable pagination, ties on the primary sort column break on `id`.
  # Translation:
  #
  #   ascending  → (sort_key, id) >  (cursor_sort_key, cursor_id)
  #   descending → (sort_key, id) <  (cursor_sort_key, cursor_id)
  #
  # SQLite handles row-value comparisons cleanly via the expanded form:
  #
  #   (sort_key > cursor_sort_key) OR
  #     (sort_key = cursor_sort_key AND id > cursor_id)
  defp apply_cursor(query, _sort_by, _order, nil), do: query

  defp apply_cursor(query, sort_by, :asc, {sort_value, id}) do
    field = sort_field(sort_by)

    from f in query,
      where:
        field(f, ^field) > ^sort_value or
          (field(f, ^field) == ^sort_value and f.id > ^id)
  end

  defp apply_cursor(query, sort_by, :desc, {sort_value, id}) do
    field = sort_field(sort_by)

    from f in query,
      where:
        field(f, ^field) < ^sort_value or
          (field(f, ^field) == ^sort_value and f.id < ^id)
  end

  defp order_by_sort(query, sort_by, :asc) do
    field = sort_field(sort_by)
    from f in query, order_by: [asc: field(f, ^field), asc: f.id]
  end

  defp order_by_sort(query, sort_by, :desc) do
    field = sort_field(sort_by)
    from f in query, order_by: [desc: field(f, ^field), desc: f.id]
  end

  defp sort_field(:path), do: :path
  defp sort_field(:size), do: :size
  defp sort_field(:mtime_us), do: :mtime_us
  defp sort_field(:indexed_at_us), do: :indexed_at_us

  # Fetched `limit + 1` rows: if we got the extra one there's a next page.
  defp finalize_page(rows, limit, sort_by) do
    if length(rows) > limit do
      page = Enum.take(rows, limit)
      last = List.last(page)
      {page, {Map.fetch!(last, sort_field(sort_by)), last.id}}
    else
      {rows, :eol}
    end
  end
end
