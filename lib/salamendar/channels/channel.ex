defmodule Salamendar.Channels.Channel do
  @moduledoc """
  A Slack channel, identified by workspace (`slack_team_id`) and channel ID
  (`slack_channel_id`), with its calendar settings.
  """

  use Salamendar.Schema
  import Ecto.Changeset

  alias Salamendar.Channels.{Canvas, Membership}
  alias Salamendar.TimeZones

  @type t :: %__MODULE__{}

  schema "slack_channels" do
    field :slack_team_id, :string
    field :slack_channel_id, :string
    field :name, :string
    field :is_private, :boolean, default: false
    field :time_zone, :string
    field :week_start, :integer, default: 0
    field :calendar_enabled, :boolean, default: false
    field :archived_at, :utc_datetime_usec

    has_many :canvases, Canvas
    has_many :memberships, Membership

    timestamps()
  end

  @doc false
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(channel, attrs) do
    channel
    |> cast(attrs, [
      :slack_team_id,
      :slack_channel_id,
      :name,
      :is_private,
      :time_zone,
      :week_start,
      :calendar_enabled,
      :archived_at
    ])
    |> validate_required([:slack_team_id, :slack_channel_id])
    |> validate_number(:week_start, greater_than_or_equal_to: 0, less_than_or_equal_to: 6)
    |> TimeZones.validate(:time_zone)
    |> check_constraint(:week_start, name: :slack_channels_week_start_range)
    |> unique_constraint([:slack_team_id, :slack_channel_id])
  end
end
