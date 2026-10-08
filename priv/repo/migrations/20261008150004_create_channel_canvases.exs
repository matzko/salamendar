defmodule Salamendar.Repo.Migrations.CreateChannelCanvases do
  use Ecto.Migration

  def change do
    create table(:channel_canvases) do
      add :channel_id, references(:slack_channels, on_delete: :delete_all), null: false
      add :kind, :string, null: false
      # Null until the canvas is created in Slack.
      add :slack_canvas_id, :string
      # The period the canvas currently shows, e.g. "2026-10" or "2026-W41".
      add :rendered_period, :string
      # Lets sync skip edits that change nothing.
      add :content_hash, :string
      add :rendered_at, :utc_datetime_usec

      timestamps()
    end

    create unique_index(:channel_canvases, [:channel_id, :kind])

    create constraint(:channel_canvases, :channel_canvases_kind,
             check: "kind IN ('month', 'week')"
           )
  end
end
