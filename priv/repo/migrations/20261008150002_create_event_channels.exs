defmodule Salamendar.Repo.Migrations.CreateEventChannels do
  use Ecto.Migration

  def change do
    # Composite primary key: `many_to_many` with a table-name `join_through`
    # only inserts the two foreign keys, so a generated `id` would be null.
    create table(:event_channels, primary_key: false) do
      add :event_id, references(:events, on_delete: :delete_all),
        null: false,
        primary_key: true

      add :channel_id, references(:slack_channels, on_delete: :delete_all),
        null: false,
        primary_key: true
    end

    create index(:event_channels, [:channel_id])
  end
end
