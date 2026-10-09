defmodule Salamendar.Accounts.User do
  @moduledoc """
  A Slack user, identified by workspace (`slack_team_id`) and user ID
  (`slack_user_id`).
  """

  use Salamendar.Schema
  import Ecto.Changeset

  alias Salamendar.TimeZones

  @type t :: %__MODULE__{}

  schema "users" do
    field :slack_team_id, :string
    field :slack_user_id, :string
    field :name, :string
    field :time_zone, :string
    field :profile_synced_at, :utc_datetime_usec

    timestamps()
  end

  @doc false
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(user, attrs) do
    user
    |> cast(attrs, [:slack_team_id, :slack_user_id, :name, :time_zone, :profile_synced_at])
    |> validate_required([:slack_team_id, :slack_user_id])
    |> TimeZones.validate(:time_zone)
    |> unique_constraint([:slack_team_id, :slack_user_id])
  end
end
