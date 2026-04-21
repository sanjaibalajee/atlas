defmodule Atlas.Projection.BroadcastTest do
  @moduledoc """
  Verifies that `Atlas.Projection.Projector` emits the expected
  `Phoenix.PubSub` messages on `Atlas.PubSub` after each event is applied.
  These broadcasts are the seam LiveView consumes; if they regress, the
  UI silently stops updating.
  """

  use ExUnit.Case, async: false

  @moduletag :nif

  alias Atlas.Library
  alias Atlas.Locations

  setup do
    dir = Path.join(System.tmp_dir!(), "atlas_bcast_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    :ok = Phoenix.PubSub.subscribe(Atlas.PubSub, Library.locations_topic())

    on_exit(fn ->
      _ = Locations.remove(dir)
      File.rm_rf(dir)
      Phoenix.PubSub.unsubscribe(Atlas.PubSub, Library.locations_topic())
    end)

    {:ok, dir: dir}
  end

  test "LocationAdded produces a :location_changed :added message", %{dir: dir} do
    {:ok, loc} = Locations.add(dir)

    assert_receive {:location_changed, %{kind: :added, location_id: id, path: path}}, 1_000

    assert id == loc.id
    assert path == Path.expand(dir)
  end

  test "LocationRemoved produces a :location_changed :removed message", %{dir: dir} do
    {:ok, _} = Locations.add(dir)
    # Flush the :added message from add/1
    assert_receive {:location_changed, %{kind: :added}}, 1_000

    :ok = Locations.remove(dir)

    assert_receive {:location_changed, %{kind: :removed, path: path}}, 1_000
    assert path == Path.expand(dir)
  end

  test "FileIndexed produces a :file_changed :indexed message on the location topic",
       %{dir: dir} do
    {:ok, loc} = Locations.add(dir)
    :ok = Phoenix.PubSub.subscribe(Atlas.PubSub, Library.location_topic(loc.id))

    File.write!(Path.join(dir, "hello.txt"), "world")
    {:ok, _} = Locations.scan(dir)

    assert_receive {:file_changed,
                    %{
                      kind: :indexed,
                      path: path,
                      file_id: file_id,
                      location_id: loc_id,
                      seq: seq
                    }},
                   1_000

    assert String.ends_with?(path, "hello.txt")
    assert is_integer(file_id)
    assert loc_id == loc.id
    assert is_integer(seq) and seq > 0
  end

  test "FileDeleted produces a :file_changed :deleted message", %{dir: dir} do
    {:ok, loc} = Locations.add(dir)
    :ok = Phoenix.PubSub.subscribe(Atlas.PubSub, Library.location_topic(loc.id))

    file = Path.join(dir, "gone.txt")
    File.write!(file, "alive")
    {:ok, _} = Locations.scan(dir)

    # Consume the indexed broadcast.
    assert_receive {:file_changed, %{kind: :indexed}}, 1_000

    File.rm!(file)
    {:ok, _} = Locations.scan(dir)

    # Non-watched scan won't emit deletion — send the FileDeleted event
    # directly through the log so we exercise the broadcaster.
    expanded = Path.expand(file)

    {:ok, seq} =
      Atlas.Log.append(%Atlas.Domain.Event.FileDeleted{
        v: 1,
        at: Atlas.Domain.Event.now_us(),
        path: expanded
      })

    :ok = Atlas.Projection.Projector.catch_up_to(seq)

    assert_receive {:file_changed, %{kind: :deleted, path: ^expanded, location_id: loc_id}},
                   1_000

    assert loc_id == loc.id
  end

  test "telemetry fires on broadcast", %{dir: dir} do
    handler_id = "broadcast-test-#{System.unique_integer([:positive])}"
    test_pid = self()

    :telemetry.attach(
      handler_id,
      [:atlas, :projection, :broadcast],
      fn _name, measurements, metadata, _ ->
        send(test_pid, {:telemetry, measurements, metadata})
      end,
      nil
    )

    try do
      {:ok, _} = Locations.add(dir)
      assert_receive {:telemetry, %{latency_us: _}, %{kind: :added, topic: :location}}, 1_000
    after
      :telemetry.detach(handler_id)
    end
  end
end
