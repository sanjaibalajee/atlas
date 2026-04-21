defmodule AtlasWeb.FileBrowserTelemetryTest do
  @moduledoc """
  Verifies the telemetry events the file browser emits so the metrics
  dashboard (M2.8) can read them without surprise. Attaches a handler,
  drives the LiveView, asserts expected events fire.
  """

  use AtlasWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  @moduletag :nif

  alias Atlas.Library
  alias Atlas.Locations
  alias Atlas.Log
  alias Atlas.Projection.Projector

  setup do
    dir = Path.join(System.tmp_dir!(), "atlas_tel_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "one.txt"), "1")
    File.write!(Path.join(dir, "two.txt"), "2")

    {:ok, _} = Locations.add(dir)
    location = Locations.get(dir)
    :ok = Projector.catch_up_to(Log.head())

    on_exit(fn ->
      _ = Locations.remove(dir)
      File.rm_rf(dir)
    end)

    {:ok, dir: dir, location: location}
  end

  defp attach_handler(events) do
    id = "tel-test-#{System.unique_integer([:positive])}"
    test_pid = self()

    :telemetry.attach_many(
      id,
      events,
      fn name, meas, meta, _ -> send(test_pid, {:telemetry, name, meas, meta}) end,
      nil
    )

    on_exit = fn -> :telemetry.detach(id) end
    {:ok, on_exit}
  end

  test "file browser emits :mount and :stream_insert events",
       %{conn: conn, location: location} do
    {:ok, detach} =
      attach_handler([
        [:atlas_web, :file_browser, :mount],
        [:atlas_web, :file_browser, :stream_insert]
      ])

    try do
      {:ok, _view, _html} = live(conn, ~p"/l/#{location.id}")

      assert_receive {:telemetry, [:atlas_web, :file_browser, :mount], %{duration_us: _}, _}, 1_000

      assert_receive {:telemetry, [:atlas_web, :file_browser, :stream_insert], %{count: count},
                      %{cause: :initial_page, location_id: loc_id}},
                     1_000

      assert count >= 2
      assert loc_id == location.id
    after
      detach.()
    end
  end

  test "projector broadcast telemetry fires on file events",
       %{conn: conn, dir: dir, location: location} do
    {:ok, detach} = attach_handler([[:atlas, :projection, :broadcast]])

    try do
      {:ok, _view, _} = live(conn, ~p"/l/#{location.id}")

      File.write!(Path.join(dir, "new.txt"), "new content")
      {:ok, _} = Locations.scan(dir)
      :ok = Projector.catch_up_to(Log.head())

      assert_receive {:telemetry, [:atlas, :projection, :broadcast], %{latency_us: _},
                      %{topic: :file, kind: :indexed}},
                     1_000
    after
      detach.()
    end

    assert Library.file_stats(location.id).files_count >= 3
  end
end
