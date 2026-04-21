defmodule AtlasTest do
  use ExUnit.Case, async: true

  test "data_dir is configured" do
    assert is_binary(Atlas.data_dir())
  end

  test "derived paths all live under data_dir" do
    root = Atlas.data_dir()
    assert String.starts_with?(Atlas.store_dir(), root)
    assert String.starts_with?(Atlas.log_db_path(), root)
    assert String.starts_with?(Atlas.projection_db_path(), root)
  end
end
