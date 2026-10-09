defmodule Salamendar.Bot do
  @moduledoc """
  Slack bot for Salamendar.

  Handles incoming Slack events delivered via Socket Mode:

    * `@salamendar` mentions in channels (`app_mention` events).
    * Direct messages (`message` events with `channel_type: "im"`).
    * `/salamendar` slash commands.
    * Block Kit interactions (`interactive` envelopes carrying a
      `block_actions` payload). Delivery depends on the app's
      *Interactivity & Shortcuts → Interactivity* toggle being on and on the
      `matzko/slack_elixir` fork that dispatches these envelopes.

  The third argument to `handle_event/3` is the `Slack.Bot` struct (bot
  identity and token); the return value is ignored.

  Replies go straight through `chat.postMessage` rather than the library's
  `send_message/2`: that macro casts to a per-channel `Slack.MessageServer`
  which only exists for channels the bot has joined, so replies to slash
  commands in other channels (or to new DMs) would be silently dropped.
  """

  use Slack.Bot
  require Logger

  alias Salamendar.SlackAPI

  @impl Slack.Bot
  def handle_event("app_mention", %{"channel" => channel} = payload, _bot) do
    Logger.info("app_mention from #{payload["user"]}: #{inspect(payload["text"])}")

    post("chat.postMessage", %{
      channel: channel,
      text: "Hi <@#{payload["user"]}>! :wave:",
      thread_ts: payload["thread_ts"] || payload["ts"],
      blocks: hello_blocks(payload["user"])
    })
  end

  def handle_event("message", %{"channel_type" => "im", "channel" => channel} = payload, _bot) do
    if is_nil(payload["subtype"]) do
      Logger.info("DM from #{payload["user"]}: #{inspect(payload["text"])}")
      post("chat.postMessage", %{channel: channel, text: "You said: #{payload["text"]}"})
    end
  end

  def handle_event("slash_commands", %{"command" => command} = payload, _bot) do
    Logger.info("#{command} from #{payload["user_id"]}: #{inspect(payload["text"])}")

    # Ephemeral, so it works even in channels the bot isn't a member of.
    post("chat.postEphemeral", %{
      channel: payload["channel_id"],
      user: payload["user_id"],
      text: "Got `#{command} #{payload["text"]}`",
      blocks: hello_blocks(payload["user_id"])
    })
  end

  def handle_event("interactive", %{"type" => "block_actions"} = payload, _bot) do
    user = get_in(payload, ["user", "id"])
    channel = get_in(payload, ["channel", "id"]) || get_in(payload, ["container", "channel_id"])

    for %{"action_id" => action_id} = action <- payload["actions"] || [] do
      Logger.info("block_action #{action_id} from #{user}: #{inspect(action["value"])}")

      # Ephemeral reply: only the clicker sees it.
      post("chat.postEphemeral", %{
        channel: channel,
        user: user,
        text: "You clicked `#{action_id}` (value: #{inspect(action["value"])})"
      })
    end
  end

  def handle_event(type, payload, _bot) do
    Logger.debug("Unhandled event #{inspect(type)}: #{inspect(payload)}")
  end

  defp post(method, body) do
    case SlackAPI.post(method, body) do
      {:ok, _} = ok -> ok
      error -> Logger.error("#{method} failed: #{inspect(error)}")
    end
  end

  defp hello_blocks(user) do
    [
      %{
        type: "section",
        text: %{type: "mrkdwn", text: "Hi <@#{user}>! Salamendar is connected. Try a button:"}
      },
      %{
        type: "actions",
        elements: [
          %{
            type: "button",
            action_id: "salamendar_ping",
            text: %{type: "plain_text", text: "Ping"},
            value: "ping"
          }
        ]
      }
    ]
  end
end
