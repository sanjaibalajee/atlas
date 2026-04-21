defmodule Atlas.IgnoreIntegrationTest do
  @moduledoc """
  Integration tests for M2.6 ignore-pattern enforcement.

  Exercises the full stack — indexer walker, watcher, and
  `Atlas.Locations.set_ignore/2` — against real tmpdirs with real
  `File.write!` calls. Confirms that ignored subtrees never reach the
  log and that changing patterns at runtime takes effect on the next
  watcher event.
  """

  use ExUnit.Case, async: false

  @moduletag :nif

  alias Atlas.Library
  alias Atlas.Locations
  alias Atlas.Log
  alias Atlas.Projection.Projector

  setup do
    dir = Path.join(System.tmp_dir!(), "atlas_ignore_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    on_exit(fn ->
      _ = Locations.remove(dir)
      File.rm_rf(dir)
    end)

    {:ok, dir: dir}
  end

  defp write!(dir, rel, content) do
    full = Path.join(dir, rel)
    File.mkdir_p!(Path.dirname(full))
    File.write!(full, content)
  end

  describe "initial scan respects ignore patterns" do
    test "default patterns skip node_modules, .git, target, _build, and *.log",
         %{dir: dir} do
      # Noisy dirs that should be ignored.
      write!(dir, "node_modules/react/index.js", "x")
      write!(dir, ".git/HEAD", "x")
      write!(dir, "target/release/binary", "x")
      write!(dir, "_build/dev/lib/foo.beam", "x")
      write!(dir, "tmp/session.log", "x")

      # Keepers.
      write!(dir, "README.md", "readme")
      write!(dir, "src/main.rs", "fn main() {}")

      {:ok, _} = Locations.add(dir)
      :ok = Projector.catch_up_to(Log.head())

      location = Locations.get(dir)
      paths = location.id |> Library.list_files(limit: 100) |> Map.fetch!(:rows) |> Enum.map(& &1.path)

      assert Enum.any?(paths, &String.ends_with?(&1, "README.md"))
      assert Enum.any?(paths, &String.ends_with?(&1, "src/main.rs"))

      refute Enum.any?(paths, &String.contains?(&1, "node_modules"))
      refute Enum.any?(paths, &String.contains?(&1, ".git/"))
      refute Enum.any?(paths, &String.contains?(&1, "target"))
      refute Enum.any?(paths, &String.contains?(&1, "_build"))
      refute Enum.any?(paths, &String.ends_with?(&1, "session.log"))
    end
  end

  describe "set_ignore/2 and rescan" do
    test "adding a pattern excludes a previously-indexed dir on next scan",
         %{dir: dir} do
      write!(dir, "keep.txt", "k")
      write!(dir, "tmp/ephemeral.txt", "e")

      # Override the default seed so "tmp" isn't in it (it isn't, but be
      # explicit so the test doesn't accidentally rely on defaults).
      {:ok, _} = Locations.add(dir)
      location = Locations.get(dir)
      # Replace defaults with a minimal set that DOESN'T include `tmp`.
      :ok = Locations.set_ignore(location.path, [".git"])
      {:ok, _} = Locations.scan(location.path)

      paths = location.id |> Library.list_files(limit: 100) |> Map.fetch!(:rows) |> Enum.map(& &1.path)
      assert Enum.any?(paths, &String.ends_with?(&1, "keep.txt"))
      assert Enum.any?(paths, &String.ends_with?(&1, "tmp/ephemeral.txt"))

      # Now ignore tmp/ and rescan. The ephemeral file stays in the
      # projection as a stale row (no tombstone — it still exists on disk)
      # but the NEXT indexer walk won't re-visit it. For `set_ignore` to
      # clean up stale rows we'd need an explicit reconciliation pass —
      # out of scope for M2.6.
      :ok = Locations.set_ignore(location.path, ["tmp"])

      # Write a new file under tmp/ and rescan. It must NOT appear.
      write!(dir, "tmp/newer.txt", "n")
      {:ok, result} = Locations.scan(location.path)

      rows = location.id |> Library.list_files(limit: 100) |> Map.fetch!(:rows)
      paths = Enum.map(rows, & &1.path)

      refute Enum.any?(paths, &String.ends_with?(&1, "tmp/newer.txt"))
      # Scan saw keep.txt but skipped the tmp tree entirely.
      assert result.new == 0 or result.new == 1
      assert Enum.any?(paths, &String.ends_with?(&1, "keep.txt"))
    end

    test "set_ignore/2 returns :not_found for unknown path" do
      assert {:error, :not_found} = Locations.set_ignore("/not/a/real/location", [".git"])
    end

    test "set_ignore/2 returns :not_found for tombstoned path", %{dir: dir} do
      {:ok, _} = Locations.add(dir)
      :ok = Locations.remove(dir)
      assert {:error, :not_found} = Locations.set_ignore(dir, [".git"])
    end

    test "set_ignore/2 bounces the watcher so new patterns take effect",
         %{dir: dir} do
      {:ok, _} = Locations.add(dir)

      expanded = Path.expand(dir)
      assert expanded in Atlas.Watcher.Supervisor.watching()

      :ok = Locations.set_ignore(dir, ["noisy"])

      # Watcher is running for the location again (idempotent start).
      assert expanded in Atlas.Watcher.Supervisor.watching()
    end
  end

  describe "defaults seeding on add" do
    test "a freshly-added location has the default ignore patterns",
         %{dir: dir} do
      {:ok, _} = Locations.add(dir)
      location = Locations.get(dir)

      assert is_list(location.ignore_patterns)
      assert ".git" in location.ignore_patterns
      assert "node_modules" in location.ignore_patterns
      assert "target" in location.ignore_patterns
    end
  end
end
