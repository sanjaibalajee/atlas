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
      case Library.list_locations() do
        [] ->
          {:ok, view, _html} = live(conn, ~p"/")
          assert has_element?(view, "[data-testid='empty-state']")

        _locs ->
          # A prior test seeded locations that share the projection;
          # verify /l/:id below.
          {:ok, view, _html} = live(conn, ~p"/")
          refute has_element?(view, "[data-testid='empty-state']")
      end
    end

    test "sidebar lists locations with stable links", %{conn: conn, dir: dir} do
      location = seed_location!(dir, [{"a.txt", "alpha"}])

      {:ok, view, _html} = live(conn, ~p"/")
      assert has_element?(view, ~s|a[href="/l/#{location.id}"]|)
    end
  end

  describe "malformed URL params" do
    test "non-integer location_id falls back gracefully", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/l/not-an-int")
      # The LiveView must survive and show the :index fallback rather than
      # crash with ArgumentError.
      assert html =~ "Atlas"
      assert render(view) =~ "Invalid location id"
    end

    test "non-integer file_id falls back gracefully", %{conn: conn, dir: dir} do
      location = seed_location!(dir, [{"a.txt", "1"}])

      {:ok, view, _html} = live(conn, ~p"/l/#{location.id}/f/nope")
      # Modal is not opened; location pane still renders.
      refute has_element?(view, "#file-detail")
      assert render(view) =~ "Invalid file id"
    end
  end

  describe ":show action" do
    test "renders the file list", %{conn: conn, dir: dir} do
      location = seed_location!(dir, [{"alpha.txt", "1"}, {"beta.txt", "2"}])
      %{rows: rows} = Library.list_files(location.id)
      ids = Enum.map(rows, & &1.id)

      {:ok, view, _html} = live(conn, ~p"/l/#{location.id}")

      for id <- ids, do: assert(has_element?(view, "#file-#{id}"))
    end

    test "new file raises the N-new toast; refresh loads it", %{conn: conn, dir: dir} do
      location = seed_location!(dir, [{"a.txt", "hello"}])

      {:ok, view, _html} = live(conn, ~p"/l/#{location.id}")
      refute has_element?(view, "[data-testid='pending-new-alert']")

      File.write!(Path.join(dir, "live_new.txt"), "fresh")
      {:ok, _} = Locations.scan(dir)
      :ok = Projector.catch_up_to(Log.head())

      assert eventually(fn ->
               has_element?(view, "[data-testid='pending-new-alert']")
             end)

      view |> element("button", "Refresh") |> render_click()

      new_file = Atlas.Repo.get_by(Atlas.Schemas.File, path: Path.join(location.path, "live_new.txt"))
      assert has_element?(view, "#file-#{new_file.id}")
    end

    test "live-updates an already-visible file in place", %{conn: conn, dir: dir} do
      file_path = Path.join(dir, "mutable.txt")
      File.write!(file_path, "short")
      location = seed_location!(dir, [])

      file = Atlas.Repo.get_by(Atlas.Schemas.File, path: Path.expand(file_path))

      {:ok, view, _} = live(conn, ~p"/l/#{location.id}")
      assert has_element?(view, "#file-#{file.id}")

      files_count = view |> element("[data-testid='files-count']") |> render()
      assert files_count =~ ">1<"

      Process.sleep(1100)
      File.write!(file_path, String.duplicate("x", 4096))
      {:ok, _} = Locations.scan(dir)
      :ok = Projector.catch_up_to(Log.head())

      # In-place row update (id stable) AND header bytes refresh.
      assert eventually(fn ->
               view
               |> element("[data-testid='bytes-total']")
               |> render() =~ "4.0 KiB"
             end)
    end

    test "deleted file disappears from the stream", %{conn: conn, dir: dir} do
      location = seed_location!(dir, [{"ghost.txt", "spooky"}])

      file =
        Atlas.Repo.get_by(Atlas.Schemas.File, path: Path.expand(Path.join(dir, "ghost.txt")))

      {:ok, view, _} = live(conn, ~p"/l/#{location.id}")
      assert has_element?(view, "#file-#{file.id}")

      target = Path.expand(Path.join(dir, "ghost.txt"))

      {:ok, seq} =
        Log.append(%Event.FileDeleted{
          v: 1,
          at: Event.now_us(),
          path: target
        })

      :ok = Projector.catch_up_to(seq)

      assert eventually(fn -> not has_element?(view, "#file-#{file.id}") end)
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
