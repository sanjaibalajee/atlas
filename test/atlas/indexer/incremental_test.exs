defmodule Atlas.Indexer.IncrementalTest do
  @moduledoc """
  Integration tests for Phase 1 M1.2 — incremental indexing.

  These tests exercise the running `Atlas` application (live log,
  projector, repo) against a fresh tmpdir per test. They are not async
  because they share the global projection state.
  """

  use ExUnit.Case, async: false

  @moduletag :nif

  alias Atlas.Domain.Event
  alias Atlas.Log
  alias Atlas.Projection.Projector

  setup do
    dir = Path.join(System.tmp_dir!(), "atlas_incr_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    baseline = Log.head()
    {:ok, dir: dir, baseline: baseline}
  end

  defp index_and_sync(dir) do
    {:ok, result} = Atlas.Indexer.index(dir)
    :ok = Projector.catch_up_to(Log.head())
    result
  end

  defp events_since(seq) do
    seq |> Log.stream() |> Enum.to_list()
  end

  test "first index emits FileIndexed events", %{dir: dir, baseline: b} do
    File.write!(Path.join(dir, "a.txt"), "hello")
    File.write!(Path.join(dir, "b.txt"), "world")

    r = index_and_sync(dir)
    assert r.new == 2
    assert r.modified == 0
    assert r.unchanged == 0

    events = events_since(b)
    assert length(events) == 2
    assert Enum.all?(events, fn {_, e} -> match?(%Event.FileIndexed{}, e) end)
  end

  test "re-indexing unchanged files emits no events", %{dir: dir, baseline: b} do
    File.write!(Path.join(dir, "a.txt"), "hello")
    index_and_sync(dir)
    after_first = Log.head()

    r = index_and_sync(dir)
    assert r.unchanged == 1
    assert r.new == 0
    assert r.modified == 0
    assert Log.head() == after_first, "log should not grow on an unchanged re-scan"
    _ = b
  end

  test "modifying a file emits FileModified", %{dir: dir, baseline: b} do
    file = Path.join(dir, "c.txt")
    File.write!(file, "hello")
    index_and_sync(dir)

    # mtime is posix-second resolution on most filesystems — wait past the
    # second boundary so the stat change is observable.
    Process.sleep(1100)
    File.write!(file, "hello world")

    r = index_and_sync(dir)
    assert r.modified == 1
    assert r.new == 0
    assert r.unchanged == 0

    events = events_since(b)
    {_, last_event} = List.last(events)
    assert %Event.FileModified{path: p} = last_event
    assert p == Path.expand(file)
  end

  test "mixed new/modified/unchanged in one scan", %{dir: dir, baseline: _b} do
    unchanged = Path.join(dir, "unchanged.txt")
    modified = Path.join(dir, "modified.txt")
    File.write!(unchanged, "static")
    File.write!(modified, "v1")
    index_and_sync(dir)

    # Bump mtime past 1s boundary and rewrite only `modified`.
    Process.sleep(1100)
    File.write!(modified, "v2-longer")
    File.write!(Path.join(dir, "fresh.txt"), "brand new")

    r = index_and_sync(dir)
    assert r.new == 1
    assert r.modified == 1
    assert r.unchanged == 1
  end
end
