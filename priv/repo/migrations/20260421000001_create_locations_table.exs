defmodule Atlas.Repo.Migrations.CreateLocationsTable do
  use Ecto.Migration

  def change do
    create table(:locations) do
      add :path, :string, null: false
      add :added_at_us, :integer, null: false
      add :removed_at_us, :integer
      add :last_scanned_at_us, :integer
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:locations, [:path])
  end
end
