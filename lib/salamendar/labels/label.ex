defmodule Salamendar.Labels.Label do
  @moduledoc """
  A name and a color that events can be tagged with ("On call", red).

  A label is either personal (`user_id` set), usable only on its owner's
  events, or shared by the workspace (`user_id` nil), usable on anyone's.
  `created_by_id` records who made it, which decides who may change a
  shared label.
  """

  use Salamendar.Schema
  import Ecto.Changeset

  alias Salamendar.Accounts.User
  alias Salamendar.Colors
  alias Salamendar.Emoji

  @type t :: %__MODULE__{}

  @name_max_length 50

  schema "labels" do
    field :slack_team_id, :string
    belongs_to :user, User
    belongs_to :created_by, User
    field :name, :string
    # A `Salamendar.Colors` key.
    field :color, :string

    timestamps()
  end

  @doc """
  Casts the name and color. `slack_team_id`, `user_id` and `created_by_id`
  are set on the struct by the caller. `:name:` shortcodes in the name
  become emoji.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(label, attrs) do
    label
    |> cast(attrs, [:name, :color])
    |> update_change(:name, &String.trim/1)
    |> update_change(:name, &Emoji.replace_shortcodes/1)
    |> validate_required([:slack_team_id, :name, :color])
    |> validate_length(:name, max: @name_max_length)
    # The column is varchar(255), which counts code points: 👨‍👩‍👧‍👦 is seven.
    |> validate_length(:name, max: 255, count: :codepoints)
    |> validate_inclusion(:color, Colors.keys())
    |> check_constraint(:color, name: :labels_color)
    |> unique_constraint(:name, name: :labels_personal_name, message: "is already used")
    |> unique_constraint(:name, name: :labels_shared_name, message: "is already used")
  end
end
