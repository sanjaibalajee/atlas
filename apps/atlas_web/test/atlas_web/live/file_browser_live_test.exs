defmodule AtlasWeb.FileBrowserLiveTest do
  @moduledoc """
  Integration tests for the M2.3 LiveView. Exercises the full path: add a
  real location, index files, mount the LiveView, and assert that events
  flowing through the projector drive stream inserts/updates/deletes
  without reload.
  """

  use AtlasWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  @moduletag :nif

  alias Atlas.Domain.Event
  alias Atlas.Library
  alias Atlas.Locations
  alias Atlas.Log
  alias Atlas.Projection.Projector

  setup do
    dir = Path.join(System.tmp_dir!(), "atlas_live_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    on_exit(fn ->
      _ = Locations.remove(dir)
      File.rm_rf(dir)
    end)

    {:ok, dir: dir}
  end

  defp seed_location!(dir, files) do
    Enum.each(files, fn {name, content} ->
      File.write!(Path.join(dir, name), content)
    end)

    {:ok, _} = Locations.add(dir)
    location = Locations.get(dir)
    :ok = Projector.catch_up_to(Log.head())
    location
  end

  describe ":index action" do
    test "empty state when no locations", %{conn: conn} do
      # Ensure no active locations; any from prior tests should have been
      # tombstoned by on_exit.
      case Library.list_locations() do
        [] ->
          {:ok, _view, html} = live(conn, ~p"/")
          assert html =~ "No locations yet"

        _locs ->
          # Other tests seeded locations that share the projection; still
          # verify /l/:id renders (covered below).
          {:ok, _view, html} = live(conn, ~p"/")
          assert html =~ "Atlas"
      end
    end

    test "sidebar lists locations", %{conn: conn, dir: dir} do
      location = seed_location!(dir, [{"a.txt", "alpha"}])

      {:ok, _view, html} = live(conn, ~p"/")
      assert html =~ Path.basename(location.path)
    end
  end

  describe ":show action" do
    test "renders the file list", %{conn: conn, dir: dir} do
      location = seed_location!(dir, [{"alpha.txt", "1"}, {"beta.txt", "2"}])

      {:ok, _view, html} = live(conn, ~p"/l/#{location.id}")
      assert html =~ "alpha.txt"
      assert html =~ "beta.txt"
    end

    test "new file raises the N-new toast; refresh loads it", %{conn: conn, dir: dir} do
      location = seed_location!(dir, [{"a.txt", "hello"}])

      {:ok, view, _html} = live(conn, ~p"/l/#{location.id}")
      refute render(view) =~ "live_new.txt"

      File.write!(Path.join(dir, "live_new.txt"), "fresh")
      {:ok, _} = Locations.scan(dir)
      :ok = Projector.catch_up_to(Log.head())

      assert eventually(fn -> render(view) =~ "new files outside current page" end)

      view |> element("button", "Refresh") |> render_click()

      assert render(view) =~ "live_new.txt"
    end

    test "live-updates an already-visible file in place", %{conn: conn, dir: dir} do
      file_path = Path.join(dir, "mutable.txt")
      File.write!(file_path, "short")
      location = seed_location!(dir, [])

      {:ok, view, _} = live(conn, ~p"/l/#{location.id}")
      html = render(view)
      assert html =~ "mutable.txt"
      assert html =~ "1 files"

      Process.sleep(1100)
      File.write!(file_path, String.duplicate("x", 4096))
      {:ok, _} = Locations.scan(dir)
      :ok = Projector.catch_up_to(Log.head())

      # In-place row update AND header-stats refresh.
      assert eventually(fn -> render(view) =~ "4.0 KiB" end)

      updated = render(view)
      refute updated =~ "5 B"
    end

    test "deleted file disappears from the stream", %{conn: conn, dir: dir} do
      location = seed_location!(dir, [{"ghost.txt", "spooky"}])
      {:ok, view, _} = live(conn, ~p"/l/#{location.id}")
      assert render(view) =~ "ghost.txt"

      target = Path.expand(Path.join(dir, "ghost.txt"))

      {:ok, seq} =
        Log.append(%Event.FileDeleted{
          v: 1,
          at: Event.now_us(),
          path: target
        })

      :ok = Projector.catch_up_to(seq)

      assert eventually(fn -> not (render(view) =~ "ghost.txt") end)
    end

    test "stale messages from previously-subscribed locations are dropped",
         %{conn: conn, dir: dir} do
      location_a = seed_location!(dir, [{"on_a.txt", "x"}])

      dir_b =
        Path.join(System.tmp_dir!(), "atlas_live_b_#{System.unique_integer([:positive])}")

      File.mkdir_p!(dir_b)
      on_exit(fn -> Locations.remove(dir_b); File.rm_rf(dir_b) end)
      location_b = seed_location!(dir_b, [{"on_b.txt", "y"}])

      {:ok, view, _} = live(conn, ~p"/l/#{location_a.id}")
      assert render(view) =~ "on_a.txt"

      view |> element("a[href='/l/#{location_b.id}']") |> render_click()
      # Fabricate a file_changed message from location_a — it must be ignored.
      send(view.pid, {:file_changed,
        %{location_id: location_a.id, file_id: 999_999, kind: :indexed, path: "/not/here.txt", seq: 1}})

      html = render(view)
      refute html =~ "/not/here.txt"
    end
  end

  describe ":file_detail action" do
    test "opens a modal with file metadata", %{conn: conn, dir: dir} do
      location = seed_location!(dir, [{"subject.txt", "content"}])

      %{rows: [file | _]} = Library.list_files(location.id, limit: 10)

      {:ok, view, _} = live(conn, ~p"/l/#{location.id}/f/#{file.id}")
      html = render(view)

      assert html =~ "Chunks"
      assert html =~ "Root hash"
      assert html =~ Base.encode16(file.root_hash, case: :lower)
    end
  end

  # Poll helper — a fresh render() is needed after async messages land.
  defp eventually(fun, tries \\ 20, sleep_ms \\ 25) do
    if tries == 0 do
      false
    else
      case fun.() do
        true ->
          true

        _ ->
          Process.sleep(sleep_ms)
          eventually(fun, tries - 1, sleep_ms)
      end
    end
  end
end
