defmodule Atlas.Schemas.JsonList do
  @moduledoc """
  Ecto type that transparently serialises a list of strings as JSON text
  in a SQLite `text` column. Used for `locations.ignore_patterns`.

  Why not `{:array, :string}`? Ecto's SQLite3 adapter does not implement
  native arrays. JSON text is SQLite-idiomatic and round-trips cleanly.
  """

  use Ecto.Type

  @impl true
  def type, do: :string

  @impl true
  def cast(value) when is_list(value) do
    if Enum.all?(value, &is_binary/1), do: {:ok, value}, else: :error
  end

  def cast(nil), do: {:ok, []}
  def cast(_), do: :error

  @impl true
  def load(nil), do: {:ok, []}

  def load(text) when is_binary(text) do
    case Jason.decode(text) do
      {:ok, list} when is_list(list) ->
        if Enum.all?(list, &is_binary/1), do: {:ok, list}, else: :error

      _ ->
        :error
    end
  end

  def load(_), do: :error

  @impl true
  def dump(list) when is_list(list) do
    if Enum.all?(list, &is_binary/1), do: {:ok, Jason.encode!(list)}, else: :error
  end

  def dump(_), do: :error
end
