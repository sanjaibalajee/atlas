defmodule Atlas.LocationsScanTest do
  @moduledoc """
  Tests for M1.7 — scan lifecycle tracking on locations.
  """

  use ExUnit.Case, async: false

  @moduletag :nif

  alias Atlas.Locations

  setup do
    dir = Path.join(System.tmp_dir!(), "atlas_scan_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "a.txt"), "hello")

    on_exit(fn ->
      _ = Locations.remove(dir)
      File.rm_rf(dir)
    end)

    {:ok, _} = Locations.add(dir)

    {:ok, dir: dir}
  end

  test "initial add records both scan_started_at_us and last_scanned_at_us", %{dir: dir} do
    loc = Locations.get(dir)
    assert is_integer(loc.scan_started_at_us)
    assert is_integer(loc.last_scanned_at_us)
    assert loc.last_scanned_at_us >= loc.scan_started_at_us,
           "completion timestamp should not precede the start timestamp"
  end

  test "scan/1 updates timestamps on subsequent runs", %{dir: dir} do
    loc_before = Locations.get(dir)

    Process.sleep(5)
    {:ok, _result} = Locations.scan(dir)
    loc_after = Locations.get(dir)

    assert loc_after.scan_started_at_us > loc_before.scan_started_at_us
    assert loc_after.last_scanned_at_us > loc_before.last_scanned_at_us
  end
end
