defmodule Salamendar.Repo.Migrations.CreateUsers do
  use Ecto.Migration

  def change do
    create table(:users) do
      # Slack user IDs are only unique within a workspace, so key on both.
      add :slack_team_id, :string, null: false
      add :slack_user_id, :string, null: false
      add :name, :string
      # IANA zone from Slack's `users.info` (`tz`), e.g. "America/Chicago".
      add :time_zone, :string

      timestamps()
    end

    create unique_index(:users, [:slack_team_id, :slack_user_id])
  end
end
