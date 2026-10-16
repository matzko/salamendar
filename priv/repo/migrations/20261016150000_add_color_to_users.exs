defmodule Salamendar.Repo.Migrations.AddColorToUsers do
  use Ecto.Migration

  # `Salamendar.Colors.keys/0` when this was written. A migration that adds
  # a color replaces the constraint with the new list.
  @keys ~w(red orange yellow green blue purple brown graphite)

  def change do
    alter table(:users) do
      # A palette key. Null means "derive one from the user's ID".
      add :color, :string
    end

    create constraint(:users, :users_color,
             check: "color IN (#{Enum.map_join(@keys, ", ", &"'#{&1}'")})"
           )
  end
end
