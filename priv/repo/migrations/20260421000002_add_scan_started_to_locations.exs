defmodule Atlas.Repo.Migrations.AddScanStartedToLocations do
  use Ecto.Migration

  def change do
    alter table(:locations) do
      add :scan_started_at_us, :integer
    end
  end
end
