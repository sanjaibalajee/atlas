defmodule Atlas.WatcherTest do
  @moduledoc """
  Integration test for the filesystem watcher. Real FSEvents are flaky
  under short time windows, so this test allows generous polling and
  only asserts eventual consistency.

  Paths note: macOS FSEvents canonicalizes through `/private/...`
  symlinks, so the path embedded in an emitted event may differ from the
  path we passed to `File.write!/2`. We compare by filename suffix.
  """

  use ExUnit.Case, async: false

  @moduletag :nif

  alias Atlas.Domain.Event
  alias Atlas.Locations
  alias Atlas.Log

  @poll_ms 50
  @deadline_ms 4_000

  setup do
    dir = Path.join(System.tmp_dir!(), "atlas_watcher_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    on_exit(fn ->
      _ = Locations.remove(dir)
      File.rm_rf(dir)
    end)

    {:ok, _} = Locations.add(dir)
    # Let FSEvents / inotify arm the watch before the test fires changes.
    Process.sleep(500)
    {:ok, dir: dir}
  end

  defp wait_for(fun, deadline_ms \\ @deadline_ms) do
    deadline = System.monotonic_time(:millisecond) + deadline_ms

    Stream.repeatedly(fn ->
      if fun.() do
        :ok
      else
        Process.sleep(@poll_ms)
        :retry
      end
    end)
    |> Enum.find(fn r -> r == :ok or System.monotonic_time(:millisecond) > deadline end)
    |> case do
      :ok -> :ok
      _ -> :timeout
    end
  end

  test "creating a new file produces a FileIndexed event", %{dir: dir} do
    before_head = Log.head()
    File.write!(Path.join(dir, "new_file.txt"), "hello world")

    result =
      wait_for(fn ->
        Log.stream(before_head)
        |> Enum.any?(fn {_, e} ->
          match?(%Event.FileIndexed{}, e) and String.ends_with?(e.path, "/new_file.txt")
        end)
      end)

    assert result == :ok, "expected a FileIndexed event for new_file.txt within #{@deadline_ms}ms"
  end

  test "deleting a file produces a FileDeleted event", %{dir: dir} do
    path = Path.join(dir, "dying.txt")
    File.write!(path, "goodbye")

    # Wait for the watcher to index it first.
    :ok =
      wait_for(fn ->
        Log.stream(0)
        |> Enum.any?(fn {_, e} ->
          match?(%Event.FileIndexed{}, e) and String.ends_with?(e.path, "/dying.txt")
        end)
      end)

    before_head = Log.head()
    File.rm!(path)

    result =
      wait_for(fn ->
        Log.stream(before_head)
        |> Enum.any?(fn {_, e} ->
          match?(%Event.FileDeleted{}, e) and String.ends_with?(e.path, "/dying.txt")
        end)
      end)

    assert result == :ok, "expected a FileDeleted event for dying.txt within #{@deadline_ms}ms"
  end
end
