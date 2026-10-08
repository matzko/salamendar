defmodule Salamendar.Repo.Migrations.CreateEvents do
  use Ecto.Migration

  def change do
    create table(:events) do
      add :slack_team_id, :string, null: false
      add :owner_id, references(:users, on_delete: :nilify_all)
      add :title, :string, null: false
      add :description, :text
      add :all_day, :boolean, null: false, default: false
      # Timed events only. Ranges are half-open: [starts_at, ends_at).
      add :starts_at, :utc_datetime_usec
      add :ends_at, :utc_datetime_usec
      # All-day events only. Ranges are half-open: [start_date, end_date).
      add :start_date, :date
      add :end_date, :date
      # The creator's IANA zone; recurrence will expand occurrences in it.
      add :time_zone, :string, null: false

      timestamps()
    end

    create index(:events, [:starts_at])
    create index(:events, [:start_date])
    create index(:events, [:owner_id])

    # An event is either all-day (dates only) or timed (timestamps only), and
    # its end is after its start.
    create constraint(:events, :events_time_shape,
             check: """
             (all_day
               AND start_date IS NOT NULL AND end_date IS NOT NULL
               AND starts_at IS NULL AND ends_at IS NULL
               AND end_date > start_date)
             OR
             (NOT all_day
               AND starts_at IS NOT NULL AND ends_at IS NOT NULL
               AND start_date IS NULL AND end_date IS NULL
               AND ends_at > starts_at)
             """
           )
  end
end
