defmodule Atlas.Log do
  @moduledoc """
  Append-only event log — the **only** source of truth in Atlas.

  Every state change must be appended here before any projection or side
  effect is considered committed. Events are returned in insertion order
  when streamed; sequence numbers are monotonic and gap-free.

  Swap backends with the `:atlas, :log_backend` application env.
  Default is `Atlas.Log.SqliteLog`.
  """

  alias Atlas.Domain.Event

  @type seq :: pos_integer()

  @callback append(Event.t()) :: {:ok, seq()} | {:error, term()}
  @callback stream(from :: non_neg_integer()) :: Enumerable.t()
  @callback head() :: non_neg_integer()

  @spec append(Event.t()) :: {:ok, seq()} | {:error, term()}
  def append(event), do: backend().append(event)

  @doc """
  Stream events whose sequence number is strictly greater than `from`.
  Passing `0` (the default) replays from the beginning.
  """
  @spec stream(non_neg_integer()) :: Enumerable.t()
  def stream(from \\ 0), do: backend().stream(from)

  @doc "The highest assigned sequence number. `0` when the log is empty."
  @spec head() :: non_neg_integer()
  def head, do: backend().head()

  defp backend do
    Application.get_env(:atlas, :log_backend, Atlas.Log.SqliteLog)
  end
end
