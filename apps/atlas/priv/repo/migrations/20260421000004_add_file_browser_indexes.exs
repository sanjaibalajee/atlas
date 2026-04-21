defmodule Atlas.Repo.Migrations.AddFileBrowserIndexes do
  use Ecto.Migration

  # Composite indexes for `Atlas.Library.list_files/2`. Each covers a
  # supported sort column plus `id` for the keyset tiebreaker. `deleted_at_us`
  # leads because the WHERE always filters on it.
  def change do
    create index(:files, [:deleted_at_us, :path, :id])
    create index(:files, [:deleted_at_us, :size, :id])
    create index(:files, [:deleted_at_us, :mtime_us, :id])
    create index(:files, [:deleted_at_us, :indexed_at_us, :id])
  end
end
