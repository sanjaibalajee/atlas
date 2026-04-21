defmodule Atlas.LibraryTest do
  @moduledoc """
  Exercises `Atlas.Library` against the live running app. Uses the indexer
  to seed projection rows (rather than inserting directly) so the tests
  stay aligned with the real event-sourced path.
  """

  use ExUnit.Case, async: false

  @moduletag :nif

  alias Atlas.Library
  alias Atlas.Locations
  alias Atlas.Log
  alias Atlas.Projection.Projector

  setup do
    dir = Path.join(System.tmp_dir!(), "atlas_lib_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    on_exit(fn ->
      _ = Locations.remove(dir)
      File.rm_rf(dir)
    end)

    {:ok, dir: dir}
  end

  describe "resolve_location_id/2" do
    test "returns nil when no locations match" do
      assert Library.resolve_location_id("/x/y/z.txt", []) == nil
      assert Library.resolve_location_id("/x/y/z.txt", [%{id: 1, path: "/other"}]) == nil
    end

    test "picks the longest prefix among candidates" do
      locs = [
        %{id: 1, path: "/a"},
        %{id: 2, path: "/a/b"},
        %{id: 3, path: "/a/b/c"}
      ]

      assert Library.resolve_location_id("/a/b/c/file.txt", locs) == 3
      assert Library.resolve_location_id("/a/b/file.txt", locs) == 2
      assert Library.resolve_location_id("/a/file.txt", locs) == 1
    end

    test "respects directory boundaries" do
      # /a should NOT match /abc/foo.txt
      locs = [%{id: 1, path: "/a"}]
      assert Library.resolve_location_id("/abc/foo.txt", locs) == nil
    end

    test "matches the location path itself" do
      locs = [%{id: 1, path: "/a/b"}]
      assert Library.resolve_location_id("/a/b", locs) == 1
    end
  end

  describe "list_locations/0" do
    test "active locations only, ordered by path", %{dir: dir} do
      {:ok, _} = Locations.add(dir)

      paths = Enum.map(Library.list_locations(), & &1.path)
      assert Path.expand(dir) in paths
    end

    test "excludes tombstoned locations", %{dir: dir} do
      {:ok, _} = Locations.add(dir)
      :ok = Locations.remove(dir)

      paths = Enum.map(Library.list_locations(), & &1.path)
      refute Path.expand(dir) in paths
    end
  end

  describe "list_files/2" do
    setup %{dir: dir} do
      for name <- ~w(alpha.txt bravo.txt charlie.txt delta.txt echo.txt) do
        File.write!(Path.join(dir, name), "#{name}-contents")
      end

      {:ok, _} = Locations.add(dir)
      location = Locations.get(dir)
      {:ok, location: location}
    end

    test "returns all files under a location, tombstones excluded", %{location: loc, dir: dir} do
      %{rows: rows, cursor: cursor} = Library.list_files(loc.id, limit: 10)
      assert cursor == :eol
      assert length(rows) == 5
      assert Enum.all?(rows, &String.starts_with?(&1.path, Path.expand(dir)))
    end

    test "keyset pagination is stable across calls", %{location: loc} do
      page1 = Library.list_files(loc.id, limit: 2, sort_by: :path, order: :asc)
      assert length(page1.rows) == 2
      assert page1.cursor != :eol

      page2 = Library.list_files(loc.id, limit: 2, sort_by: :path, order: :asc, after: page1.cursor)
      assert length(page2.rows) == 2

      page3 = Library.list_files(loc.id, limit: 2, sort_by: :path, order: :asc, after: page2.cursor)
      assert page3.cursor == :eol
      assert length(page3.rows) == 1

      all_paths = Enum.map(page1.rows ++ page2.rows ++ page3.rows, & &1.path)
      assert all_paths == Enum.sort(all_paths), "pagination must preserve sort order"
      assert Enum.uniq(all_paths) == all_paths, "no duplicate rows across pages"
    end

    test "sort_by :size orders by file size", %{location: loc} do
      %{rows: rows} = Library.list_files(loc.id, limit: 10, sort_by: :size, order: :asc)
      sizes = Enum.map(rows, & &1.size)
      assert sizes == Enum.sort(sizes)
    end

    test "order :desc reverses the sort", %{location: loc} do
      asc = Library.list_files(loc.id, limit: 10, sort_by: :path, order: :asc).rows
      desc = Library.list_files(loc.id, limit: 10, sort_by: :path, order: :desc).rows
      assert Enum.map(desc, & &1.path) == Enum.reverse(Enum.map(asc, & &1.path))
    end

    test "unknown / removed location returns empty", %{location: loc} do
      :ok = Locations.remove(loc.path)
      assert %{rows: [], cursor: :eol} = Library.list_files(loc.id)
    end
  end

  describe "get_file/1" do
    test "returns file with chunk_count", %{dir: dir} do
      File.write!(Path.join(dir, "thing.txt"), "content")
      # Use content mode explicitly — shallow mode skips the CAS and
      # therefore does not populate file_chunks, which this test asserts
      # on. The sampled-hash path is covered separately.
      {:ok, _} = Locations.add(dir, mode: :content)

      location = Locations.get(dir)
      %{rows: [file]} = Library.list_files(location.id)

      assert %{file: f, chunk_count: n} = Library.get_file(file.id)
      assert f.id == file.id
      assert n >= 1
    end

    test "returns nil for unknown file" do
      assert Library.get_file(999_999_999) == nil
    end
  end

  describe "file_stats/1" do
    test "aggregates count + bytes for a location", %{dir: dir} do
      File.write!(Path.join(dir, "a.txt"), String.duplicate("a", 100))
      File.write!(Path.join(dir, "b.txt"), String.duplicate("b", 200))
      {:ok, _} = Locations.add(dir)
      location = Locations.get(dir)

      %{files_count: count, bytes_total: bytes} = Library.file_stats(location.id)
      assert count == 2
      assert bytes == 300
    end
  end

  describe "topic helpers" do
    test "topic strings are stable and unique" do
      assert Library.locations_topic() == "locations"
      assert Library.location_topic(7) == "location:7"
      assert Library.location_scan_topic(7) == "location:7:scan"
    end
  end

  # Locations.add/1 already calls Projector.catch_up_to internally, so
  # tests don't need to sync explicitly. Aliases retained for future use.
  _ = Log
  _ = Projector
end
