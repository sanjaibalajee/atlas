defmodule AtlasWeb.FileHelpers do
  @moduledoc """
  Display-time formatters used by the file browser LiveView and its
  component templates. Kept separate from `CoreComponents` so the Phoenix
  scaffold stays untouched.
  """

  @doc "First 8 hex characters of a binary BLAKE3 hash — enough to eyeball."
  @spec short_hash(binary() | nil) :: String.t()
  def short_hash(nil), do: ""

  def short_hash(bin) when is_binary(bin) do
    bin |> Base.encode16(case: :lower) |> binary_part(0, min(8, byte_size(bin) * 2))
  end

  @doc "Full hex of a binary BLAKE3 hash."
  @spec full_hash(binary() | nil) :: String.t()
  def full_hash(nil), do: ""
  def full_hash(bin) when is_binary(bin), do: Base.encode16(bin, case: :lower)

  @doc ~S"""
  Human-friendly byte count using binary prefixes. Matches the quick visual
  calibration of `ls -lh`.

      iex> AtlasWeb.FileHelpers.format_size(0)
      "0 B"
      iex> AtlasWeb.FileHelpers.format_size(1023)
      "1023 B"
      iex> AtlasWeb.FileHelpers.format_size(1024)
      "1.0 KiB"
      iex> AtlasWeb.FileHelpers.format_size(1_572_864)
      "1.5 MiB"
  """
  @spec format_size(non_neg_integer() | nil) :: String.t()
  def format_size(nil), do: ""
  def format_size(0), do: "0 B"

  def format_size(bytes) when is_integer(bytes) and bytes < 1024, do: "#{bytes} B"

  def format_size(bytes) when is_integer(bytes) do
    units = ["B", "KiB", "MiB", "GiB", "TiB", "PiB"]
    exp = min(floor(:math.log(bytes) / :math.log(1024)), length(units) - 1)
    value = bytes / :math.pow(1024, exp)
    unit = Enum.at(units, exp)
    :io_lib.format("~.1f ~s", [value, unit]) |> IO.iodata_to_binary()
  end

  @doc """
  Relative time ("5m ago") for microsecond-resolution timestamps. Returns an
  ISO-style absolute date once the gap exceeds ~1 year.
  """
  @spec format_relative_time(integer() | nil, integer()) :: String.t()
  def format_relative_time(us, now_us \\ System.os_time(:microsecond))

  def format_relative_time(nil, _now), do: ""

  def format_relative_time(us, now_us) when is_integer(us) do
    seconds = div(now_us - us, 1_000_000)

    cond do
      seconds < 5 -> "just now"
      seconds < 60 -> "#{seconds}s ago"
      seconds < 3600 -> "#{div(seconds, 60)}m ago"
      seconds < 86_400 -> "#{div(seconds, 3600)}h ago"
      seconds < 2_592_000 -> "#{div(seconds, 86_400)}d ago"
      seconds < 31_536_000 -> "#{div(seconds, 2_592_000)}mo ago"
      true -> DateTime.from_unix!(us, :microsecond) |> DateTime.to_date() |> Date.to_string()
    end
  end

  @doc """
  Drop the location's path prefix from a file path so the list shows
  relative paths. `/home/me/pics/cat.jpg` under location `/home/me/pics`
  renders as `cat.jpg`.
  """
  @spec relative_path(String.t(), String.t()) :: String.t()
  def relative_path(file_path, location_path) do
    prefix =
      if String.ends_with?(location_path, "/"),
        do: location_path,
        else: location_path <> "/"

    cond do
      file_path == location_path -> Path.basename(location_path)
      String.starts_with?(file_path, prefix) -> binary_slice(file_path, byte_size(prefix)..-1//1)
      true -> file_path
    end
  end

  @doc "Last path segment of a location for sidebar display."
  @spec location_name(String.t()) :: String.t()
  def location_name(path), do: Path.basename(path)
end
