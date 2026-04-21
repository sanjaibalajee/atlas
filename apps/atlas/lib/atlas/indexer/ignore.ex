defmodule Atlas.Indexer.Ignore do
  @moduledoc """
  Fast glob-based ignore matcher for the walker + watcher.

  Pattern semantics (a pragmatic subset of `.gitignore`):

    * Pattern has **no `/`** (e.g. `.git`, `node_modules`, `*.log`) —
      matches the basename of any segment at any depth. So `.git` matches
      `src/.git/config`, `.git`, `a/b/.git/x`. `*.log` matches any file
      whose final segment ends in `.log` at any depth.

    * Pattern **contains a `/`** (e.g. `build/out`, `**/cache`) — matches
      the full relative path (from the location root) as a glob. Leading
      `/` anchors to root; the leading slash is stripped before matching.

    * `**` — matches any run of characters including `/`.
    * `*`  — matches any run of characters **except** `/`.
    * `?`  — matches any single character except `/`.
    * Any other character matches itself literally.

  Match is **pure** (no DB, no FS, no processes). Compile once with
  `compile/1`, then call `match?/2` repeatedly in a hot walk loop.

  ## Example

      iex> m = Atlas.Indexer.Ignore.compile([".git", "node_modules", "*.log"])
      iex> Atlas.Indexer.Ignore.match?(m, "src/.git/HEAD")
      true
      iex> Atlas.Indexer.Ignore.match?(m, "node_modules/react/index.js")
      true
      iex> Atlas.Indexer.Ignore.match?(m, "main.rs")
      false
      iex> Atlas.Indexer.Ignore.match?(m, "tmp/session.log")
      true
  """

  @type compiled :: %__MODULE__{segment: [Regex.t()], full: [Regex.t()]}

  defstruct segment: [], full: []

  @doc """
  Compile a list of pattern strings into a matcher. Empty / comment lines
  (starting with `#`) are skipped. Whitespace-only patterns are skipped.
  """
  @spec compile([String.t()] | nil) :: compiled()
  def compile(nil), do: %__MODULE__{}
  def compile([]), do: %__MODULE__{}

  def compile(patterns) when is_list(patterns) do
    patterns
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))
    |> Enum.reduce(%__MODULE__{}, fn raw, acc ->
      case classify(raw) do
        {:segment, regex} -> %{acc | segment: [regex | acc.segment]}
        {:full, regex} -> %{acc | full: [regex | acc.full]}
      end
    end)
  end

  @doc """
  Does `relative_path` (relative to the location root, using `/` separators)
  match any pattern in the compiled matcher?
  """
  @spec match?(compiled(), String.t()) :: boolean()
  def match?(%__MODULE__{segment: [], full: []}, _path), do: false

  def match?(%__MODULE__{segment: segs, full: fulls}, path) do
    segments = String.split(path, "/", trim: true)

    Enum.any?(segs, fn regex ->
      Enum.any?(segments, &Regex.match?(regex, &1))
    end) or
      Enum.any?(fulls, &Regex.match?(&1, path))
  end

  @doc """
  Reasonable out-of-the-box ignores for "pointing Atlas at a home
  directory." Users can edit/replace via the location settings UI.
  """
  @spec default_patterns() :: [String.t()]
  def default_patterns do
    [
      # VCS + OS
      ".git",
      ".hg",
      ".svn",
      ".DS_Store",
      "Thumbs.db",
      # Editors
      ".idea",
      ".vscode",
      ".cursor",
      # JS / TS
      "node_modules",
      ".next",
      ".nuxt",
      ".turbo",
      "dist",
      "build",
      ".cache",
      # Python
      "__pycache__",
      ".venv",
      "venv",
      ".pytest_cache",
      ".mypy_cache",
      # Rust
      "target",
      # Elixir / Erlang
      "_build",
      "deps",
      ".elixir_ls",
      # Misc
      ".Trash",
      ".npm",
      ".yarn",
      "*.log",
      "*.tmp",
      "*.swp"
    ]
  end

  # --- Private ---

  # `**/foo` means "foo at any depth including root" — same semantics as a
  # bare basename pattern, so classify it as one.
  defp classify("**/" <> rest), do: classify_segment_or_full(strip_trailing_slash(rest))

  # A leading `/` anchors the pattern to the location root. Strip it and
  # treat as a full-path pattern regardless of whether the remainder has
  # more slashes.
  defp classify("/" <> rest), do: {:full, compile_path_glob(strip_trailing_slash(rest))}

  defp classify(pattern), do: classify_segment_or_full(strip_trailing_slash(pattern))

  defp classify_segment_or_full(pattern) do
    cond do
      pattern == "" -> {:segment, compile_segment_glob("")}
      String.contains?(pattern, "/") -> {:full, compile_path_glob(pattern)}
      true -> {:segment, compile_segment_glob(pattern)}
    end
  end

  defp strip_trailing_slash(p) do
    if String.ends_with?(p, "/"), do: String.trim_trailing(p, "/"), else: p
  end

  # Translate a glob into an anchored regex. `**` must be recognised BEFORE
  # `*` so we don't mis-escape it, and the literal segments must be regex-
  # escaped to survive `.`, `+`, `(`, etc. in file names.
  #
  # Tokens emitted:
  #
  #     "**"  -> ".*"               (any chars including /)
  #     "*"   -> "[^/]*"            (any chars except /)
  #     "?"   -> "[^/]"             (any single char except /)
  #     other -> Regex.escape(chunk)
  #
  # Segment globs match a single path segment exactly. Path globs also
  # match the pattern's descendants — ignoring a directory ignores its
  # contents too, mirroring gitignore semantics.
  defp compile_segment_glob(pattern) do
    body = pattern |> tokenize() |> Enum.map_join(&token_to_regex/1)
    Regex.compile!("\\A" <> body <> "\\z")
  end

  defp compile_path_glob(pattern) do
    body = pattern |> tokenize() |> Enum.map_join(&token_to_regex/1)
    Regex.compile!("\\A" <> body <> "(?:/.*)?\\z")
  end

  defp tokenize(""), do: []

  defp tokenize("**" <> rest), do: [:star_star | tokenize(rest)]
  defp tokenize("*" <> rest), do: [:star | tokenize(rest)]
  defp tokenize("?" <> rest), do: [:question | tokenize(rest)]

  defp tokenize(other) do
    {literal, rest} = take_literal(other, "")
    [{:literal, literal} | tokenize(rest)]
  end

  defp take_literal(<<c, rest::binary>>, acc) when c in [?*, ??],
    do: {acc, <<c>> <> rest}

  defp take_literal(<<c, rest::binary>>, acc), do: take_literal(rest, acc <> <<c>>)
  defp take_literal(<<>>, acc), do: {acc, ""}

  defp token_to_regex(:star_star), do: ".*"
  defp token_to_regex(:star), do: "[^/]*"
  defp token_to_regex(:question), do: "[^/]"
  defp token_to_regex({:literal, lit}), do: Regex.escape(lit)
end
