defmodule Salamendar.Channels.Membership do
  @moduledoc """
  A user's membership in a calendar-enabled channel: a local copy of Slack
  membership, used to build each user's Home tab.
  """

  use Salamendar.Schema

  alias Salamendar.Accounts.User
  alias Salamendar.Channels.Channel

  @type t :: %__MODULE__{}

  # Keyed on (user_id, channel_id) rather than a generated ID.
  @primary_key false

  schema "channel_memberships" do
    belongs_to :user, User, primary_key: true
    belongs_to :channel, Channel, primary_key: true

    timestamps(updated_at: false)
  end
end
