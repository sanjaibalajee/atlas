defmodule Atlas.Domain.ChunkTest do
  use ExUnit.Case, async: true

  alias Atlas.Domain.Chunk

  defp c(offset, length, hash), do: %Chunk{offset: offset, length: length, hash: hash}

  test "total_size/1 sums lengths" do
    chunks = [c(0, 100, <<0::256>>), c(100, 200, <<1::256>>), c(300, 50, <<2::256>>)]
    assert Chunk.total_size(chunks) == 350
  end

  @tag :nif
  test "root_hash/1 changes when any chunk changes" do
    h1 = <<1::256>>
    h2 = <<2::256>>
    h3 = <<3::256>>

    a = [c(0, 1, h1), c(1, 1, h2)]
    b = [c(0, 1, h1), c(1, 1, h3)]

    refute Chunk.root_hash(a) == Chunk.root_hash(b)
  end

  @tag :nif
  test "root_hash/1 is order-sensitive" do
    h1 = <<1::256>>
    h2 = <<2::256>>

    a = [c(0, 1, h1), c(1, 1, h2)]
    b = [c(0, 1, h2), c(1, 1, h1)]

    refute Chunk.root_hash(a) == Chunk.root_hash(b)
  end
end
