defmodule Atlas.Indexer.WalkerTest do
  use ExUnit.Case, async: true

  alias Atlas.Indexer.Walker

  setup do
    root = Path.join(System.tmp_dir!(), "atlas_walker_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "a/b/c"))
    File.write!(Path.join(root, "top.txt"), "top")
    File.write!(Path.join(root, "a/mid.txt"), "mid")
    File.write!(Path.join(root, "a/b/deep.txt"), "deep")
    File.write!(Path.join(root, "a/b/c/deepest.txt"), "deepest")

    on_exit(fn -> File.rm_rf(root) end)
    {:ok, root: root}
  end

  test "yields every regular file under root", %{root: root} do
    paths = root |> Walker.stream() |> Enum.sort()

    assert Enum.any?(paths, &String.ends_with?(&1, "top.txt"))
    assert Enum.any?(paths, &String.ends_with?(&1, "mid.txt"))
    assert Enum.any?(paths, &String.ends_with?(&1, "deep.txt"))
    assert Enum.any?(paths, &String.ends_with?(&1, "deepest.txt"))
    assert length(paths) == 4
  end

  test "returns an empty stream for a file that doesn't exist" do
    result = "/nonexistent/path" |> Walker.stream() |> Enum.to_list()
    assert result == []
  end

  test "returns the single file when root is a regular file", %{root: root} do
    target = Path.join(root, "top.txt")
    assert [^target] = target |> Walker.stream() |> Enum.to_list()
  end
end
