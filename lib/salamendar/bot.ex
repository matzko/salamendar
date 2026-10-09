defmodule Salamendar.Bot do
  @moduledoc """
  Slack bot for Salamendar: routes events delivered over Socket Mode to the
  handlers in `Salamendar.Handlers`.

    * `/salamendar` slash commands → `Handlers.Commands`.
    * `app_home_opened` → `Handlers.Home`.
    * Channel membership and lifecycle events → `Handlers.ChannelEvents`.
    * Block Kit interactions (`interactive` envelopes): the Home tab's "Add
      event" button and event menus, and the event form's submissions →
      `Handlers.EventForm`. Delivery depends on the app's *Interactivity*
      toggle and on the `matzko/slack_elixir` fork, which dispatches these
      envelopes and acks a `view_submission` with what its handler returns.
    * `@salamendar` mentions and direct messages get the command's help.

  The third argument to `handle_event/3` is the `Slack.Bot` struct (bot
  identity and token). The return value is ignored, except that for a
  `view_submission` an `{:ack, payload}` is sent back to Slack (e.g. form
  errors).
  """

  use Slack.Bot
  require Logger

  alias Salamendar.Handlers.{ChannelEvents, Commands, EventForm, Home}
  alias Salamendar.Render.HomeTab
  alias Salamendar.SlackAPI

  @help "Hi! Use `/salamendar` to set up a channel calendar, or open my Home tab to see today's events."

  @impl Slack.Bot
  def handle_event("slash_commands", %{"command" => "/salamendar"} = payload, bot),
    do: Commands.handle(bot.team_id, payload)

  def handle_event("app_home_opened", %{"tab" => "home", "user" => user_id}, bot) do
    case Home.publish(bot.team_id, user_id) do
      {:ok, _} -> :ok
      error -> Logger.error("Publishing #{user_id}'s Home tab failed: #{inspect(error)}")
    end
  end

  def handle_event("member_joined_channel", event, bot),
    do: ChannelEvents.member_joined(bot, event)

  def handle_event("member_left_channel", event, bot), do: ChannelEvents.member_left(bot, event)

  def handle_event(type, event, bot) when type in ["channel_left", "group_left"],
    do: ChannelEvents.bot_removed(bot, event)

  def handle_event(type, event, bot) when type in ["channel_rename", "group_rename"],
    do: ChannelEvents.renamed(bot, event)

  def handle_event(type, event, bot) when type in ["channel_archive", "group_archive"],
    do: ChannelEvents.archived(bot, event)

  def handle_event(type, event, bot) when type in ["channel_unarchive", "group_unarchive"],
    do: ChannelEvents.unarchived(bot, event)

  def handle_event(type, event, bot) when type in ["channel_deleted", "group_deleted"],
    do: ChannelEvents.deleted(bot, event)

  def handle_event("interactive", %{"type" => "view_submission", "view" => view} = payload, bot) do
    cond do
      view["callback_id"] == EventForm.form_callback_id() ->
        EventForm.submit(bot.team_id, payload)

      view["callback_id"] == EventForm.delete_callback_id() ->
        EventForm.submit_delete(bot.team_id, payload)

      true ->
        :ok
    end
  end

  def handle_event("interactive", %{"type" => "block_actions"} = payload, bot) do
    for action <- payload["actions"] || [], do: block_action(action, payload, bot)
    :ok
  end

  def handle_event("app_mention", %{"channel" => channel} = payload, _bot) do
    post("chat.postMessage", %{
      channel: channel,
      text: @help,
      thread_ts: payload["thread_ts"] || payload["ts"]
    })
  end

  def handle_event("message", %{"channel_type" => "im", "channel" => channel} = payload, _bot) do
    if is_nil(payload["subtype"]), do: post("chat.postMessage", %{channel: channel, text: @help})
  end

  def handle_event(type, payload, _bot) do
    Logger.debug("Unhandled event #{inspect(type)}: #{inspect(payload)}")
  end

  defp block_action(%{"action_id" => action_id} = action, payload, bot) do
    trigger_id = payload["trigger_id"]
    user_id = get_in(payload, ["user", "id"])
    add_event = HomeTab.add_event_action_id()
    event_menu = HomeTab.event_menu_action_id()

    result =
      case {action_id, get_in(action, ["selected_option", "value"])} do
        {^add_event, _} ->
          EventForm.open(trigger_id, bot.team_id, user_id)

        {^event_menu, "edit:" <> id} ->
          EventForm.open(trigger_id, bot.team_id, user_id, id)

        {^event_menu, "delete:" <> id} ->
          EventForm.open_delete(trigger_id, bot.team_id, user_id, id)

        _ ->
          {:ok, :ignored}
      end

    with {:error, _} = error <- result, do: Logger.error("#{action_id} failed: #{inspect(error)}")
  end

  defp post(method, body) do
    case SlackAPI.post(method, body) do
      {:ok, _} = ok -> ok
      error -> Logger.error("#{method} failed: #{inspect(error)}")
    end
  end
end
