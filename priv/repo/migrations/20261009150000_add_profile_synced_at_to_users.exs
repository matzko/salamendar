defmodule Salamendar.Repo.Migrations.AddProfileSyncedAtToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      # When `name` and `time_zone` were last fetched with `users.info`.
      # `updated_at` can't stand in for it: every upsert touches it.
      add :profile_synced_at, :utc_datetime_usec
    end
  end
end
