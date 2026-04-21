defmodule Atlas do
  @moduledoc """
  Atlas — a content-addressed, event-sourced file system.

  This module is the public API facade. Internal modules are grouped as:

    * `Atlas.Domain.*`     — pure value objects
    * `Atlas.Store.*`      — content-addressed object store
    * `Atlas.Log.*`        — append-only event log (source of truth)
    * `Atlas.Projection.*` — read-model projectors (event → Ecto)
    * `Atlas.Indexer.*`    — file walker + chunker + event producer
    * `Atlas.Native`       — Rust NIF (BLAKE3 + FastCDC)
  """

  @doc """
  Return the configured root directory for runtime state.

  All persistent data — the object store, the event log, the projection
  database — lives under this directory.
  """
  @spec data_dir() :: Path.t()
  def data_dir do
    Application.fetch_env!(:atlas, :data_dir)
  end

  @doc "Absolute path to the chunk store root."
  @spec store_dir() :: Path.t()
  def store_dir, do: Path.join(data_dir(), "store")

  @doc "Absolute path to the event log database."
  @spec log_db_path() :: Path.t()
  def log_db_path, do: Path.join(data_dir(), "log.db")

  @doc "Absolute path to the projection database."
  @spec projection_db_path() :: Path.t()
  def projection_db_path, do: Path.join(data_dir(), "projection.db")
end
# new line
