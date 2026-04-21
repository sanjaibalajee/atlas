defmodule Atlas.Repo do
  @moduledoc """
  Ecto repo for the **projection** database.

  Contrast with `Atlas.Log`, which owns the event log database. The two are
  deliberately separate SQLite files: the log is truth, the projection is
  disposable cache. Deleting `projection.db` is never destructive.
  """

  use Ecto.Repo,
    otp_app: :atlas,
    adapter: Ecto.Adapters.SQLite3
end
