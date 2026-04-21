defmodule Atlas.Repo.Migrations.AddIndexModeToLocations do
  use Ecto.Migration

  # Every location has an index mode. "shallow" (the default for new
  # locations) computes a sampled content hash per file and writes nothing
  # to the CAS — suitable for general-purpose browsing. "content" does
  # full FastCDC chunking + CAS writes, required for future sync and
  # content-addressed extensions. Users opt into content mode explicitly.
  def change do
    alter table(:locations) do
      add :index_mode, :text, default: "shallow", null: false
    end
  end
end
