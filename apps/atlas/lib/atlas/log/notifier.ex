defmodule Atlas.Log.Notifier do
  @moduledoc """
  In-process pub/sub for log events.

  The `Atlas.Log.SqliteLog` writer calls `broadcast/1` after each
  successful commit. Any process that has called `subscribe/0` receives
  an `{:event_appended, seq}` message and can catch up to `seq`.

  Implemented as a `Registry` with `keys: :duplicate` — zero external
  dependencies, safe under supervision, and ready to grow into a
  multi-topic publisher in Phase 2.
  """

  @topic :log_events

  @doc false
  def child_spec(_opts) do
    Registry.child_spec(keys: :duplicate, name: __MODULE__)
  end

  @doc "Subscribe the calling process to log-event notifications."
  @spec subscribe() :: :ok
  def subscribe do
    {:ok, _pid} = Registry.register(__MODULE__, @topic, nil)
    :ok
  end

  @doc "Unsubscribe the calling process."
  @spec unsubscribe() :: :ok
  def unsubscribe do
    Registry.unregister(__MODULE__, @topic)
    :ok
  end

  @doc "Broadcast an event-appended notification to all subscribers."
  @spec broadcast(non_neg_integer()) :: :ok
  def broadcast(seq) when is_integer(seq) and seq > 0 do
    Registry.dispatch(__MODULE__, @topic, fn entries ->
      for {pid, _} <- entries, do: send(pid, {:event_appended, seq})
    end)
  end
end
