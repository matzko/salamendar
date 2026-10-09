defmodule Salamendar.Handlers.ChannelEvents do
  @moduledoc """
  Keeps the local copy of channels and their membership in step with
  Slack's channel events.

  Events for channels Salamendar doesn't know, or that don't have the
  calendar enabled, are ignored: membership is only kept for calendar
  channels.
  """

  alias Salamendar.{Accounts, Channels}
  alias Salamendar.Channels.Channel
  alias Salamendar.Workers.DeleteCanvases

  @type bot :: %{team_id: String.t(), user_id: String.t()}

  @doc """
  `member_joined_channel`: records the membership. The bot joining is
  ignored; it isn't a calendar user.
  """
  @spec member_joined(bot(), map()) :: :ok
  def member_joined(%{user_id: bot_user_id}, %{"user" => bot_user_id}), do: :ok

  def member_joined(bot, %{"user" => user_id, "channel" => channel_id}) do
    with %Channel{calendar_enabled: true} = channel <-
           Channels.get_channel(bot.team_id, channel_id),
         {:ok, user} <- Accounts.get_or_create_user(bot.team_id, user_id) do
      Channels.add_member(channel, user)
    end

    :ok
  end

  @doc """
  `member_left_channel`: removes the membership.
  """
  @spec member_left(bot(), map()) :: :ok
  def member_left(bot, %{"user" => user_id, "channel" => channel_id}) do
    with %Channel{} = channel <- Channels.get_channel(bot.team_id, channel_id),
         {:ok, user} <- Accounts.get_or_create_user(bot.team_id, user_id) do
      Channels.remove_member(channel, user)
    end

    :ok
  end

  @doc """
  `channel_left`/`group_left` (the bot was removed): disables the calendar,
  the same as `/salamendar disable`.
  """
  @spec bot_removed(bot(), map()) :: :ok
  def bot_removed(bot, %{"channel" => channel_id}) do
    with %Channel{calendar_enabled: true} = channel <-
           Channels.get_channel(bot.team_id, channel_id) do
      disable(channel)
    end

    :ok
  end

  @doc """
  Turns `channel`'s calendar off and schedules its canvas for deletion.
  """
  @spec disable(Channel.t()) :: :ok
  def disable(%Channel{} = channel) do
    {:ok, channel, _canvases} = Channels.disable_calendar(channel)
    {:ok, _} = DeleteCanvases.enqueue(channel.id)
    :ok
  end

  @doc """
  `channel_rename`/`group_rename`.
  """
  @spec renamed(bot(), map()) :: :ok
  def renamed(bot, %{"channel" => %{"id" => channel_id, "name" => name}}) do
    with_channel(bot, channel_id, &Channels.rename_channel(&1, name))
  end

  @doc """
  `channel_archive`/`group_archive`. Canvas syncs skip archived channels.
  """
  @spec archived(bot(), map()) :: :ok
  def archived(bot, %{"channel" => channel_id}),
    do: with_channel(bot, channel_id, &Channels.archive_channel/1)

  @doc """
  `channel_unarchive`/`group_unarchive`.
  """
  @spec unarchived(bot(), map()) :: :ok
  def unarchived(bot, %{"channel" => channel_id}),
    do: with_channel(bot, channel_id, &Channels.unarchive_channel/1)

  @doc """
  `channel_deleted`/`group_deleted`: deletes the channel's row. Its events
  stay, and owners still see them on their Home tab.
  """
  @spec deleted(bot(), map()) :: :ok
  def deleted(bot, %{"channel" => channel_id}),
    do: with_channel(bot, channel_id, &Channels.delete_channel/1)

  defp with_channel(bot, channel_id, fun) do
    with %Channel{} = channel <- Channels.get_channel(bot.team_id, channel_id), do: fun.(channel)
    :ok
  end
end
