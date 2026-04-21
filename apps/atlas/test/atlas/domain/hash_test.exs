defmodule Atlas.Domain.HashTest do
  use ExUnit.Case, async: true

  alias Atlas.Domain.Hash

  @zero_hash <<0::256>>
  @zero_hex String.duplicate("0", 64)

  describe "to_hex/1" do
    test "renders 32 bytes as 64 lowercase hex chars" do
      assert Hash.to_hex(@zero_hash) == @zero_hex
    end
  end

  describe "from_hex/1" do
    test "roundtrips with to_hex" do
      assert {:ok, bin} = Hash.from_hex(@zero_hex)
      assert Hash.to_hex(bin) == @zero_hex
    end

    test "accepts both cases" do
      assert {:ok, _} = Hash.from_hex(String.duplicate("AB", 32))
      assert {:ok, _} = Hash.from_hex(String.duplicate("ab", 32))
    end

    test "rejects wrong length" do
      assert {:error, :invalid_hex} = Hash.from_hex("abc")
      assert {:error, :invalid_hex} = Hash.from_hex(String.duplicate("a", 63))
    end

    test "rejects non-hex characters" do
      assert {:error, :invalid_hex} = Hash.from_hex(String.duplicate("z", 64))
    end
  end

  describe "short/2" do
    test "defaults to 8 chars" do
      assert Hash.short(@zero_hash) == "00000000"
    end

    test "respects requested length" do
      assert Hash.short(@zero_hash, 12) == "000000000000"
    end
  end

  describe "shard/1" do
    test "is the first 2 hex chars" do
      assert Hash.shard(@zero_hash) == "00"
    end
  end

  describe "valid?/1" do
    test "true for a 32-byte binary" do
      assert Hash.valid?(@zero_hash)
      assert Hash.valid?(:crypto.strong_rand_bytes(32))
    end

    test "false for anything else" do
      refute Hash.valid?("short")
      refute Hash.valid?(:crypto.strong_rand_bytes(31))
      refute Hash.valid?(:crypto.strong_rand_bytes(33))
      refute Hash.valid?(nil)
      refute Hash.valid?(123)
    end
  end
end
