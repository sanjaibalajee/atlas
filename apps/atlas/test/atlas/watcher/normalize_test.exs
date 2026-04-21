defmodule Atlas.Watcher.NormalizeTest do
  @moduledoc """
  Locks in `Atlas.Watcher.normalize/1`. macOS FSEvents reports paths with
  the `/private` symlink prefix while user-supplied locations omit it.
  Regressing this causes silent duplicate rows and dropped broadcasts.
  """

  use ExUnit.Case, async: true

  alias Atlas.Watcher

  test "strips /private/tmp prefix" do
    assert Watcher.normalize("/private/tmp/atlas_p1_demo/a.txt") ==
             "/tmp/atlas_p1_demo/a.txt"
  end

  test "strips /private/var prefix" do
    assert Watcher.normalize("/private/var/folders/xx/yy/zz/file.log") ==
             "/var/folders/xx/yy/zz/file.log"
  end

  test "leaves already-normalised paths unchanged" do
    assert Watcher.normalize("/tmp/file.txt") == "/tmp/file.txt"
    assert Watcher.normalize("/var/log/syslog") == "/var/log/syslog"
    assert Watcher.normalize("/Users/me/project/src/main.rs") ==
             "/Users/me/project/src/main.rs"
  end

  test "does not strip /private prefixes outside /tmp and /var" do
    # FSEvents only canonicalises through the two documented tmp/var
    # symlinks; anything else like /private/etc is a real path.
    assert Watcher.normalize("/private/etc/hosts") == "/private/etc/hosts"
  end
end
