defmodule Salamendar.Repo.Migrations.AddObanJobsTable do
  use Ecto.Migration

  # Pinned to the version current when this was written; a later Oban
  # upgrade that needs a newer schema adds its own migration.
  def up, do: Oban.Migrations.up(version: 14)

  def down, do: Oban.Migrations.down(version: 1)
end
