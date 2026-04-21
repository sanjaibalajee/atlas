defmodule Atlas.Repo.Migrations.AddIgnorePatternsToLocations do
  use Ecto.Migration

  def change do
    # Stored as JSON text because SQLite has no native array type.
    # `Atlas.Schemas.Location` declares this field as `Atlas.Schemas.JsonList`
    # — a custom Ecto.Type that round-trips `[String.t()]` through JSON — with
    # an empty list as the default (no patterns = index everything).
    alter table(:locations) do
      add :ignore_patterns, :text, default: "[]", null: false
    end
  end
end
