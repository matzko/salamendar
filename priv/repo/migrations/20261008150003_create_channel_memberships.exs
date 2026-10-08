defmodule Salamendar.Repo.Migrations.CreateChannelMemberships do
  use Ecto.Migration

  def change do
    # Local copy of Slack membership, kept only for calendar-enabled channels.
    create table(:channel_memberships, primary_key: false) do
      add :user_id, references(:users, on_delete: :delete_all),
        null: false,
        primary_key: true

      add :channel_id, references(:slack_channels, on_delete: :delete_all),
        null: false,
        primary_key: true

      timestamps(updated_at: false)
    end

    create index(:channel_memberships, [:channel_id])
  end
end
