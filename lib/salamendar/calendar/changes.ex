defmodule Salamendar.Calendar.Changes do
  @moduledoc """
  Tells open web calendars that events changed, so they refetch.

  Each channel has a topic, and so does each user. A change is published on
  the topics of the channels it touches and on its owner's, which reaches
  owners who have left every channel the event is in. Subscribers get
  `:calendar_changed` and nothing else: they ask for events again rather
  than being sent them.

  Contexts don't call this. Callers broadcast after a successful change,
  using the channel IDs the context returned.
  """

  alias Salamendar.Accounts.User
  alias Salamendar.Channels

  @pubsub Salamendar.PubSub

  @doc """
  Publishes `:calendar_changed` to `channel_ids` and to `owner_id`. The
  owner is `nil` for changes to a channel rather than to an event.
  """
  @spec broadcast([Ecto.UUID.t()], Ecto.UUID.t() | nil) :: :ok
  def broadcast(channel_ids, owner_id) do
    topics = Enum.map(channel_ids, &channel_topic/1)
    topics = if owner_id, do: [user_topic(owner_id) | topics], else: topics

    for topic <- Enum.uniq(topics),
        do: :ok = Phoenix.PubSub.broadcast(@pubsub, topic, :calendar_changed)

    :ok
  end

  @doc """
  Subscribes the calling process to `user`'s own topic and to the topics of
  the calendar channels they're a member of.
  """
  @spec subscribe(User.t()) :: :ok
  def subscribe(%User{} = user) do
    topics = [
      user_topic(user.id) | Enum.map(Channels.list_member_channels(user), &channel_topic(&1.id))
    ]

    for topic <- topics, do: :ok = Phoenix.PubSub.subscribe(@pubsub, topic)
    :ok
  end

  defp channel_topic(channel_id), do: "calendar:channel:#{channel_id}"
  defp user_topic(user_id), do: "calendar:user:#{user_id}"
end
