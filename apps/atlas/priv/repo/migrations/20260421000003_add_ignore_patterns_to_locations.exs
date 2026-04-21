defmodule Atlas.Repo.Migrations.AddIgnorePatternsToLocations do
  use Ecto.Migration

  def change do
    # Stored as JSON text because SQLite has no native array type.
    # The schema casts to `{:array, :string}` via Ecto.Type, with `[]`
    # as the default (no patterns = index everything, current behavior).
    alter table(:locations) do
      add :ignore_patterns, :text, default: "[]", null: false
    end
  end
end
