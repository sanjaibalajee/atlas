defmodule Atlas.SelfIndexingGuardTest do
  @moduledoc """
  Locks in the guard that prevents Atlas from indexing its own on-disk
  state (log DB, projection DB, chunk CAS). Without this guard, pointing
  Atlas at a parent directory (like `$HOME`) would index its own
  `priv/data/store/` and create a feedback loop where every chunk-write
  temp file fires an indexer event.
  """

  use ExUnit.Case, async: false

  @moduletag :nif

  alias Atlas.Locations

  describe "Atlas.internal_path?/1" do
    test "true for the data dir and its descendants" do
      assert Atlas.internal_path?(Atlas.data_dir())
      assert Atlas.internal_path?(Atlas.store_dir())
      assert Atlas.internal_path?(Path.join(Atlas.store_dir(), "ab/cdef.bin"))
      assert Atlas.internal_path?(Atlas.log_db_path())
    end

    test "false for unrelated paths" do
      refute Atlas.internal_path?("/tmp/unrelated")
      refute Atlas.internal_path?("/Users/me/Documents")
      # Sibling paths that share a prefix but aren't under data_dir.
      refute Atlas.internal_path?(Atlas.data_dir() <> "_sibling")
    end

    test "resolves the _build symlink so real `apps/atlas/priv/data` paths match" do
      # In dev, `:code.priv_dir(:atlas)` returns `_build/<env>/lib/atlas/priv`
      # which is a symlink to `apps/atlas/priv`. FSEvents reports the
      # resolved path, not the symlinked one — so the guard must catch both.
      prefixes = Atlas.internal_path_prefixes()
      assert is_list(prefixes)
      assert length(prefixes) >= 1

      # The realpath-resolved prefix. In a dev layout it differs from the
      # symlinked one; in CI or after `mix clean` they may collapse.
      resolved =
        Enum.find(prefixes, fn p ->
          not String.contains?(p, "/_build/") and
            not String.contains?(p, "/_build\\")
        end)

      if resolved do
        store_probe = Path.join([resolved, "store", "ab", "cdef1234.tmp.42.999"])
        assert Atlas.internal_path?(store_probe)
      end
    end
  end

  describe "Locations.add/1 rejects internal paths" do
    test "refuses a path inside Atlas's data dir" do
      assert {:error, :atlas_internal_path} = Locations.add(Atlas.data_dir())

      inside = Path.join(Atlas.store_dir(), "somewhere")
      File.mkdir_p!(inside)

      on_exit(fn -> File.rm_rf(inside) end)

      assert {:error, :atlas_internal_path} = Locations.add(inside)
    end

    test "refuses a parent path that contains Atlas's data dir" do
      # The project root contains `apps/atlas/priv/data/`. Adding it as a
      # location would index the CAS and loop.
      parent = Path.expand(Path.join(Atlas.data_dir(), "../../../.."))
      assert {:error, :contains_atlas_internal_path} = Locations.add(parent)
    end
  end
end
