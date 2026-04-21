defmodule Atlas.Repo.Migrations.CreateProjectionTables do
  use Ecto.Migration

  def change do
    create table(:files) do
      add :path, :string, null: false
      add :size, :integer, null: false
      add :mtime_us, :integer, null: false
      add :root_hash, :binary, null: false
      add :deleted_at_us, :integer
      add :indexed_at_us, :integer, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:files, [:path])
    create index(:files, [:root_hash])

    create table(:chunks, primary_key: false) do
      add :hash, :binary, primary_key: true
      add :length, :integer, null: false
      add :ref_count, :integer, null: false, default: 0
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create table(:file_chunks, primary_key: false) do
      add :file_id, references(:files, on_delete: :delete_all), null: false
      add :ordinal, :integer, null: false
      add :offset, :integer, null: false
      add :length, :integer, null: false
      add :chunk_hash, :binary, null: false
    end

    create unique_index(:file_chunks, [:file_id, :ordinal])
    create index(:file_chunks, [:chunk_hash])

    # SQLite disallows ALTER TABLE ADD CONSTRAINT, so the CHECK has to be
    # inlined at table-creation time. Use raw SQL.
    execute(
      """
      CREATE TABLE projection_state (
        id INTEGER PRIMARY KEY CHECK (id = 1),
        last_applied_seq INTEGER NOT NULL DEFAULT 0
      )
      """,
      "DROP TABLE projection_state"
    )

    execute(
      "INSERT INTO projection_state(id, last_applied_seq) VALUES(1, 0)",
      "DELETE FROM projection_state"
    )
  end
end
