defmodule Salamendar.Repo.Migrations.CreateSlackChannels do
  use Ecto.Migration

  def change do
    create table(:slack_channels) do
      # Slack channel IDs are only unique within a workspace, so key on both.
      add :slack_team_id, :string, null: false
      add :slack_channel_id, :string, null: false
      # Cached copy of the channel name, refreshed on rename.
      add :name, :string
      add :is_private, :boolean, null: false, default: false
      # IANA zone; null means use the configured `:default_time_zone`.
      add :time_zone, :string
      # 0 = Sunday ... 6 = Saturday.
      add :week_start, :smallint, null: false, default: 0
      add :calendar_enabled, :boolean, null: false, default: false
      add :archived_at, :utc_datetime_usec

      timestamps()
    end

    create unique_index(:slack_channels, [:slack_team_id, :slack_channel_id])

    create constraint(:slack_channels, :slack_channels_week_start_range,
             check: "week_start BETWEEN 0 AND 6"
           )
  end
end
