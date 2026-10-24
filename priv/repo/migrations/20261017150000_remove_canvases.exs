defmodule Salamendar.Repo.Migrations.RemoveCanvases do
  use Ecto.Migration

  # The web calendar replaced the month canvas. Delete the canvases in Slack
  # before running this (see "Removing the canvas" in
  # docs/web-calendar-plan.md): their IDs are only in `channel_canvases`.

  @removed_workers ~w(
    Salamendar.Workers.SyncCanvas
    Salamendar.Workers.DeleteCanvases
    Salamendar.Workers.Rollover
  )

  def up do
    drop table(:channel_canvases)

    alter table(:slack_channels) do
      # Only the canvas read it. The web page uses the browser's zone and the
      # Home tab the user's.
      remove :time_zone
    end

    # Jobs for workers that no longer exist would only fail.
    execute "DELETE FROM oban_jobs WHERE worker = ANY(ARRAY[#{Enum.map_join(@removed_workers, ", ", &"'#{&1}'")}])"
  end

  def down do
    alter table(:slack_channels) do
      add :time_zone, :string
    end

    create table(:channel_canvases) do
      add :channel_id, references(:slack_channels, on_delete: :delete_all), null: false
      add :kind, :string, null: false
      add :slack_canvas_id, :string
      add :rendered_period, :string
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
