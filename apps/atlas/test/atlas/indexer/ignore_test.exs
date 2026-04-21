defmodule Atlas.Indexer.IgnoreTest do
  use ExUnit.Case, async: true

  alias Atlas.Indexer.Ignore

  describe "basename (no-slash) patterns" do
    test "match the basename of any path segment at any depth" do
      m = Ignore.compile([".git", "node_modules"])
      assert Ignore.match?(m, ".git")
      assert Ignore.match?(m, ".git/HEAD")
      assert Ignore.match?(m, "src/.git/config")
      assert Ignore.match?(m, "node_modules/react/index.js")
      refute Ignore.match?(m, "src/main.rs")
      refute Ignore.match?(m, "README.md")
    end

    test "glob stars stay confined to a single segment" do
      m = Ignore.compile(["*.log"])
      assert Ignore.match?(m, "session.log")
      assert Ignore.match?(m, "logs/session.log")
      refute Ignore.match?(m, "session.log.backup")
      # `*` does NOT cross `/`, so `session.log` inside a deeper path still
      # matches because we're matching per-segment.
      assert Ignore.match?(m, "a/b/c/session.log")
    end

    test "? matches a single character" do
      m = Ignore.compile(["?.tmp"])
      assert Ignore.match?(m, "a.tmp")
      assert Ignore.match?(m, "src/b.tmp")
      refute Ignore.match?(m, "ab.tmp")
    end

    test "a literal segment does not match a prefix" do
      m = Ignore.compile(["tmp"])
      assert Ignore.match?(m, "tmp")
      assert Ignore.match?(m, "tmp/a.txt")
      # regression: `tmp` should not swallow `tmpfoo`
      refute Ignore.match?(m, "tmpfoo")
      refute Ignore.match?(m, "tmpfoo/bar")
    end
  end

  describe "path (with-slash) patterns" do
    test "anchored pattern matches only at the given depth" do
      m = Ignore.compile(["build/out"])
      assert Ignore.match?(m, "build/out")
      assert Ignore.match?(m, "build/out/index.html")
      refute Ignore.match?(m, "src/build/out")
    end

    test "leading / strips and anchors to root" do
      m = Ignore.compile(["/target"])
      assert Ignore.match?(m, "target")
      assert Ignore.match?(m, "target/debug/foo")
      refute Ignore.match?(m, "crates/foo/target")
    end

    test "** crosses slashes; * does not" do
      m = Ignore.compile(["**/dist", "src/*/junk"])
      assert Ignore.match?(m, "dist")
      assert Ignore.match?(m, "a/b/c/dist")
      assert Ignore.match?(m, "src/anything/junk")
      refute Ignore.match?(m, "src/a/b/junk")
    end
  end

  describe "trailing slash" do
    test "treats foo/ the same as foo for matching" do
      m = Ignore.compile(["node_modules/"])
      assert Ignore.match?(m, "node_modules")
      assert Ignore.match?(m, "packages/x/node_modules/react/index.js")
    end
  end

  describe "compile/1 input hygiene" do
    test "skips empty lines and comments" do
      m = Ignore.compile(["", "   ", "# a comment", ".git"])
      assert Ignore.match?(m, ".git")
      refute Ignore.match?(m, "anything")
    end

    test "handles nil and [] as no-op" do
      assert Ignore.compile(nil) == %Ignore{}
      assert Ignore.compile([]) == %Ignore{}
      refute Ignore.match?(Ignore.compile(nil), "anything")
      refute Ignore.match?(Ignore.compile([]), "anything")
    end

    test "regex-meta characters in patterns are escaped" do
      # A literal `.` should match only `.`, not any char.
      m = Ignore.compile([".env"])
      assert Ignore.match?(m, ".env")
      refute Ignore.match?(m, "xenv")
      refute Ignore.match?(m, "aenv")
    end
  end

  describe "default_patterns/0" do
    test "includes the common high-noise directories" do
      defaults = Ignore.default_patterns()
      for required <- ~w(.git node_modules .DS_Store target _build deps __pycache__) do
        assert required in defaults, "expected #{required} in default ignore list"
      end
    end

    test "defaults filter realistic noisy paths" do
      m = Ignore.compile(Ignore.default_patterns())

      assert Ignore.match?(m, ".git/HEAD")
      assert Ignore.match?(m, "web/node_modules/react/index.js")
      assert Ignore.match?(m, "rust-app/target/release/binary")
      assert Ignore.match?(m, "elixir-app/_build/dev/lib/foo.beam")
      assert Ignore.match?(m, "python-app/__pycache__/thing.pyc")
      assert Ignore.match?(m, "src/.DS_Store")
      assert Ignore.match?(m, "logs/session.log")

      refute Ignore.match?(m, "src/main.rs")
      refute Ignore.match?(m, "lib/my_module.ex")
      refute Ignore.match?(m, "README.md")
      refute Ignore.match?(m, "docs/architecture.md")
    end
  end
end
