defmodule Atlas.Repo.Migrations.AddFileBrowserIndexes do
  use Ecto.Migration

  # Composite indexes for `Atlas.Library.list_files/2`. Each covers a
  # supported sort column plus `id` for the keyset tiebreaker.
  #
  # **Partial** indexes filtered on `deleted_at_us IS NULL` because the
  # list-files query always excludes tombstones. Partial indexes are
  # smaller, faster to maintain, and never load tombstone rows into the
  # pager cache. SQLite supports `CREATE INDEX ... WHERE` natively; this
  # project is SQLite-only so there is no `CONCURRENTLY` equivalent (that
  # is a Postgres feature and would not compile here).
  def change do
    create index(:files, [:path, :id],
             name: :files_live_path_id_index,
             where: "deleted_at_us IS NULL"
           )

    create index(:files, [:size, :id],
             name: :files_live_size_id_index,
             where: "deleted_at_us IS NULL"
           )

    create index(:files, [:mtime_us, :id],
             name: :files_live_mtime_us_id_index,
             where: "deleted_at_us IS NULL"
           )

    create index(:files, [:indexed_at_us, :id],
             name: :files_live_indexed_at_us_id_index,
             where: "deleted_at_us IS NULL"
           )
  end
end
