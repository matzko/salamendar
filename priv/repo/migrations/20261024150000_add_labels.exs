defmodule Salamendar.Repo.Migrations.AddLabels do
  use Ecto.Migration

  # `Salamendar.Colors.keys/0` when this was written. A migration that adds
  # a color replaces the constraint with the new list.
  @keys ~w(red orange yellow green blue purple brown graphite)

  def change do
    create table(:labels) do
      add :slack_team_id, :string, null: false
      # The owner of a personal label; null for a label shared by the
      # workspace.
      add :user_id, references(:users, on_delete: :delete_all)
      # Who made it. Once they're gone, anyone may change a shared label.
      add :created_by_id, references(:users, on_delete: :nilify_all)
      add :name, :string, null: false
      # A palette key.
      add :color, :string, null: false

      timestamps()
    end

    create constraint(:labels, :labels_color,
             check: "color IN (#{Enum.map_join(@keys, ", ", &"'#{&1}'")})"
           )

    # Names are unique within a scope, ignoring case. A personal label may
    # share a name with a shared one.
    create unique_index(:labels, ["user_id", "lower(name)"],
             name: :labels_personal_name,
             where: "user_id IS NOT NULL"
           )

    create unique_index(:labels, ["slack_team_id", "lower(name)"],
             name: :labels_shared_name,
             where: "user_id IS NULL"
           )

    create index(:labels, [:slack_team_id])

    alter table(:events) do
      add :label_id, references(:labels, on_delete: :nilify_all)
    end

    create index(:events, [:label_id])
  end
end
