defmodule Atlas.CLI do
  @moduledoc """
  Escript entry point.

  For day-to-day development prefer `mix atlas.<cmd>` — the mix tasks boot
  the app for you and don't require rebuilding the escript. The escript
  exists to produce a shippable single-file binary via `mix escript.build`.
  """

  import Ecto.Query, only: [from: 2]

  alias Atlas.Schemas.File, as: FileRow

  @spec main([String.t()]) :: :ok
  def main(args) do
    {:ok, _apps} = Application.ensure_all_started(:atlas)
    dispatch(args)
  end

  defp dispatch(["index", path]), do: cmd_index(path)
  defp dispatch(["ls" | _]), do: cmd_ls()
  defp dispatch(["find", term]), do: cmd_find(term)
  defp dispatch(["rebuild-projection"]), do: cmd_rebuild()
  defp dispatch(["watch", path]), do: cmd_watch(path)
  defp dispatch(["unwatch", path]), do: cmd_unwatch(path)
  defp dispatch(["locations"]), do: cmd_locations()
  defp dispatch(["gc"]), do: cmd_gc(dry_run: false)
  defp dispatch(["gc", "--dry-run"]), do: cmd_gc(dry_run: true)
  defp dispatch(["help"]), do: print_help()
  defp dispatch([]), do: print_help()

  defp dispatch(other) do
    IO.puts(:stderr, "unknown command: #{inspect(other)}\n")
    print_help()
    System.halt(1)
  end

  defp cmd_index(path) do
    {:ok, result} = Atlas.Indexer.index(path)
    head = Atlas.Log.head()
    :ok = Atlas.Projection.Projector.catch_up_to(head, 30_000)

    IO.puts("""
    New:       #{result.new}
    Modified:  #{result.modified}
    Unchanged: #{result.unchanged}
    Bytes:     #{format_bytes(result.bytes)}
    Errors:    #{result.errors}
    Log head:  #{head}
    """)
  end

  defp cmd_ls do
    query =
      from f in FileRow,
        where: is_nil(f.deleted_at_us),
        order_by: [asc: f.path],
        select: {f.size, f.path}

    query
    |> Atlas.Repo.all()
    |> write_lines(fn {size, path} ->
      "#{String.pad_leading(format_bytes(size), 10)}  #{path}"
    end)
  end

  defp cmd_find(term) do
    pattern = "%#{term}%"

    query =
      from f in FileRow,
        where: like(f.path, ^pattern) and is_nil(f.deleted_at_us),
        order_by: [asc: f.path],
        select: f.path

    query
    |> Atlas.Repo.all()
    |> write_lines(& &1)
  end

  # Writes each rendered line to stdout, stopping silently if the reader
  # closes the pipe (e.g. `atlas ls | head`). Without this, BEAM raises
  # ErlangError :terminated on the broken pipe instead of exiting quietly.
  defp write_lines(items, fun) do
    Enum.each(items, fn item -> IO.puts(fun.(item)) end)
  rescue
    ErlangError -> :ok
  end

  defp cmd_rebuild do
    IO.puts("Rebuilding projection from the event log…")
    :ok = Atlas.Projection.Projector.rebuild()
    IO.puts("Done. Log head: #{Atlas.Log.head()}")
  end

  defp cmd_watch(path) do
    case Atlas.Locations.add(path) do
      {:ok, loc} ->
        IO.puts("Watching #{loc.path}")
        IO.puts("Ctrl-C to stop.\n")
        :ok = Atlas.Log.Notifier.subscribe()
        watch_loop()

      {:error, reason} ->
        IO.puts(:stderr, "failed to watch #{path}: #{inspect(reason)}")
        System.halt(1)
    end
  end

  defp watch_loop do
    receive do
      {:event_appended, seq} ->
        print_latest_event(seq)
        watch_loop()
    end
  end

  defp print_latest_event(seq) do
    case seq - 1 |> Atlas.Log.stream() |> Enum.take(1) do
      [{^seq, event}] ->
        try do
          IO.puts(format_live_event(event))
        rescue
          ErlangError -> :ok
        end

      _ ->
        :ok
    end
  end

  defp format_live_event(%Atlas.Domain.Event.FileIndexed{path: p}), do: "+  #{p}"
  defp format_live_event(%Atlas.Domain.Event.FileModified{path: p}), do: "~  #{p}"
  defp format_live_event(%Atlas.Domain.Event.FileMoved{from_path: f, to_path: t}),
    do: "↻  #{f} → #{t}"
  defp format_live_event(%Atlas.Domain.Event.FileDeleted{path: p}), do: "-  #{p}"
  defp format_live_event(%Atlas.Domain.Event.LocationAdded{path: p}), do: "L+ #{p}"
  defp format_live_event(%Atlas.Domain.Event.LocationRemoved{path: p}), do: "L- #{p}"
  defp format_live_event(_), do: ""

  defp cmd_unwatch(path) do
    case Atlas.Locations.remove(path) do
      :ok ->
        IO.puts("Unwatched #{Path.expand(path)}")

      {:error, reason} ->
        IO.puts(:stderr, "failed: #{inspect(reason)}")
        System.halt(1)
    end
  end

  defp cmd_locations do
    case Atlas.Locations.list() do
      [] ->
        IO.puts("(no locations)")

      locs ->
        write_lines(locs, & &1.path)
    end
  end

  defp cmd_gc(opts) do
    result = Atlas.GC.sweep(opts)

    IO.puts("""
    Scanned:    #{result.scanned} orphan chunks
    Removed:    #{result.removed}
    Reclaimed:  #{format_bytes(result.bytes_reclaimed)}#{if opts[:dry_run], do: "  (dry run)", else: ""}
    """)
  end

  defp print_help do
    IO.puts("""

    Atlas — a content-addressed, event-sourced file system

      atlas index <path>          Walk, chunk, and log a directory tree
      atlas ls                    List indexed files (by path)
      atlas find <term>           Find files whose path contains <term>
      atlas rebuild-projection    Drop + rebuild the projection DB from the log
      atlas watch <path>          Add location, index, watch for changes (blocks)
      atlas unwatch <path>        Stop watching a location
      atlas locations             List currently watched locations
      atlas gc [--dry-run]        Reclaim orphan chunks from the CAS
      atlas help                  Show this help

    Data lives under $ATLAS_DATA_DIR (default: ~/.atlas in prod, ./priv/data in dev).
    """)
  end

  defp format_bytes(n) when n < 1024, do: "#{n} B"
  defp format_bytes(n) when n < 1_048_576, do: "#{Float.round(n / 1024, 1)} KB"
  defp format_bytes(n) when n < 1_073_741_824, do: "#{Float.round(n / 1_048_576, 1)} MB"
  defp format_bytes(n), do: "#{Float.round(n / 1_073_741_824, 2)} GB"
end
