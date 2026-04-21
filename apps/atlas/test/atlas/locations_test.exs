defmodule Atlas.LocationsTest do
  @moduledoc """
  Exercises `Atlas.Locations` against the live running app. Creates a
  fresh tmpdir per test, adds it as a location, then verifies the
  projection sees it and that the watcher is running.
  """

  use ExUnit.Case, async: false

  @moduletag :nif

  alias Atlas.Locations
  alias Atlas.Watcher.Supervisor, as: WatcherSup

  setup do
    dir = Path.join(System.tmp_dir!(), "atlas_loc_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn ->
      _ = Locations.remove(dir)
      File.rm_rf(dir)
    end)

    {:ok, dir: dir}
  end

  test "add/1 creates the row and starts a watcher", %{dir: dir} do
    assert {:ok, loc} = Locations.add(dir)
    assert loc.path == Path.expand(dir)
    assert is_nil(loc.removed_at_us)

    assert Enum.member?(WatcherSup.watching(), Path.expand(dir))
  end

  test "add/1 is idempotent", %{dir: dir} do
    assert {:ok, _} = Locations.add(dir)
    assert {:ok, _} = Locations.add(dir)
    assert Enum.count(WatcherSup.watching(), &(&1 == Path.expand(dir))) == 1
  end

  test "remove/1 tombstones the row and stops the watcher", %{dir: dir} do
    {:ok, _} = Locations.add(dir)
    assert :ok = Locations.remove(dir)

    loc = Locations.get(dir)
    assert loc.removed_at_us != nil

    refute Enum.member?(WatcherSup.watching(), Path.expand(dir))
  end

  test "list/0 returns only active locations", %{dir: dir} do
    {:ok, _} = Locations.add(dir)
    assert Enum.any?(Locations.list(), &(&1.path == Path.expand(dir)))

    :ok = Locations.remove(dir)
    refute Enum.any?(Locations.list(), &(&1.path == Path.expand(dir)))
  end
end
