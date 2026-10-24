defmodule Salamendar.Handlers.Commands do
  @moduledoc """
  The `/salamendar` slash command:

    * `enable` / `disable`: turn the channel's calendar on or off.
    * `new`: open the form for a new event.
    * `open`: reply with a sign-in link to the web calendar.
    * `week-start [day]`: show or set the calendar's first day of the week.

  Replies go to the command's `response_url` (only the user sees them),
  which works even in a private channel the bot hasn't been invited to.
  Slash commands are acknowledged before this runs, so it can call Slack.
  """

  require Logger

  alias Salamendar.{Accounts, Channels, SlackAPI}
  alias Salamendar.Channels.Channel
  alias Salamendar.Handlers.{ChannelEvents, EventForm}
  alias Salamendar.Workers.ReconcileMembers
  alias SalamendarWeb.SignInLink

  @usage """
  *Salamendar* keeps a shared calendar for your channels.
  • `/salamendar enable`: turn on the calendar in this channel
  • `/salamendar disable`: turn it off (events are kept)
  • `/salamendar new`: add an event
  • `/salamendar open`: open the calendar in your browser
  • `/salamendar week-start monday`: set the calendar's first day of the week
  """

  @weekdays ~w(sunday monday tuesday wednesday thursday friday saturday)

  @doc """
  Handles a `/salamendar` slash command payload.
  """
  @spec handle(String.t(), map()) :: :ok
  def handle(team_id, %{"text" => text} = payload) do
    case String.split(text || "") do
      ["enable"] -> enable(team_id, payload)
      ["disable"] -> disable(team_id, payload)
      ["new"] -> new_event(team_id, payload)
      ["open"] -> open(team_id, payload)
      ["week-start" | args] -> week_start(team_id, payload, args)
      _ -> reply(payload, @usage)
    end
  end

  def handle(team_id, payload), do: handle(team_id, Map.put(payload, "text", ""))

  # -- enable ---------------------------------------------------------------------

  defp enable(_team_id, %{"channel_id" => "D" <> _} = payload),
    do: reply(payload, "Run `/salamendar enable` in the channel that should get a calendar.")

  defp enable(team_id, %{"channel_id" => channel_id} = payload) do
    with {:ok, info} <- channel_info(channel_id),
         :ok <- ensure_member(info),
         {:ok, channel} <-
           Channels.upsert_channel(team_id, channel_id, %{
             name: info["name"],
             is_private: info["is_private"] || false
           }),
         {:ok, channel} <- Channels.enable_calendar(channel),
         {:ok, _} <- ReconcileMembers.enqueue(channel.id) do
      link_reply(
        team_id,
        payload,
        "The calendar is on! Add events with `/salamendar new` or from Salamendar's Home tab, " <>
          "and see them in your browser:"
      )
    else
      {:error, message} when is_binary(message) ->
        reply(payload, message)

      error ->
        Logger.error("/salamendar enable failed in #{channel_id}: #{inspect(error)}")
        reply(payload, "Sorry, something went wrong turning on the calendar. Please try again.")
    end
  end

  defp channel_info(channel_id) do
    case SlackAPI.get("conversations.info", %{channel: channel_id}) do
      {:ok, %{"channel" => info}} ->
        {:ok, info}

      # Private channels are invisible to the bot until it's invited.
      {:error, "channel_not_found"} ->
        {:error,
         "I can't see this channel yet. Invite me with `/invite @Salamendar`, then run `/salamendar enable` again."}

      error ->
        error
    end
  end

  defp ensure_member(%{"is_member" => true}), do: :ok

  defp ensure_member(%{"is_private" => true}),
    do: {:error, "Invite me with `/invite @Salamendar`, then run `/salamendar enable` again."}

  defp ensure_member(%{"id" => channel_id}) do
    case SlackAPI.post("conversations.join", %{channel: channel_id}) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  # -- disable --------------------------------------------------------------------

  defp disable(team_id, %{"channel_id" => channel_id} = payload) do
    case Channels.get_channel(team_id, channel_id) do
      %Channel{calendar_enabled: true} = channel ->
        :ok = ChannelEvents.disable(channel)

        reply(
          payload,
          "The calendar is off. Its events are kept: `/salamendar enable` brings them back."
        )

      _ ->
        reply(payload, "The calendar isn't on in this channel.")
    end
  end

  # -- new ------------------------------------------------------------------------

  defp new_event(team_id, %{"trigger_id" => trigger_id, "user_id" => user_id} = payload) do
    case EventForm.open(trigger_id, team_id, user_id) do
      {:ok, _} ->
        :ok

      error ->
        Logger.error("Opening the event form failed: #{inspect(error)}")
        reply(payload, "Sorry, I couldn't open the event form. Please try again.")
    end
  end

  # -- open -----------------------------------------------------------------------

  defp open(team_id, payload),
    do: link_reply(team_id, payload, "Here's your link to the calendar. It works for a day.")

  # Replies with `text` and a sign-in link for the user who ran the command,
  # focused on the channel. The link goes in a button: Slack doesn't unfurl
  # button URLs, so the token isn't fetched by anyone else.
  defp link_reply(team_id, %{"user_id" => user_id, "channel_id" => channel_id} = payload, text) do
    {:ok, user} = Accounts.get_or_create_user(team_id, user_id)
    url = SignInLink.url(user, focus(channel_id))

    respond(payload, %{
      text: text,
      blocks: [
        %{
          type: "section",
          text: %{type: "mrkdwn", text: text},
          accessory: %{
            type: "button",
            action_id: "open_calendar",
            url: url,
            style: "primary",
            text: %{type: "plain_text", text: "Open calendar", emoji: true}
          }
        }
      ]
    })
  end

  # Direct messages have no calendar to focus.
  defp focus("D" <> _), do: []
  defp focus(channel_id), do: [return_to: "/?" <> URI.encode_query(channel: channel_id)]

  # -- settings -------------------------------------------------------------------

  defp week_start(team_id, payload, args) do
    with_enabled_channel(team_id, payload, &set_week_start(&1, payload, args))
  end

  defp set_week_start(channel, payload, []) do
    reply(payload, "This channel's calendar starts weeks on *#{day_name(channel.week_start)}*.")
  end

  defp set_week_start(channel, payload, [day | _]) do
    case parse_weekday(day) do
      {:ok, week_start} ->
        {:ok, _channel} = Channels.update_settings(channel, %{week_start: week_start})
        reply(payload, "This channel's calendar now starts weeks on *#{day_name(week_start)}*.")

      :error ->
        reply(payload, "`#{day}` isn't a day of the week. Try `sunday` or `monday`.")
    end
  end

  defp with_enabled_channel(team_id, %{"channel_id" => channel_id} = payload, fun) do
    case Channels.get_channel(team_id, channel_id) do
      %Channel{calendar_enabled: true} = channel ->
        fun.(channel)

      _ ->
        reply(payload, "The calendar isn't on in this channel. Run `/salamendar enable` first.")
    end
  end

  # "mon", "Monday", "MON" and so on.
  defp parse_weekday(day) do
    day = String.downcase(day)

    case Enum.find_index(@weekdays, &(String.length(day) >= 2 and String.starts_with?(&1, day))) do
      nil -> :error
      index -> {:ok, index}
    end
  end

  defp day_name(index), do: @weekdays |> Enum.at(index) |> String.capitalize()

  defp reply(payload, text), do: respond(payload, %{text: text})

  defp respond(%{"response_url" => response_url}, message) do
    case SlackAPI.respond(response_url, Map.put(message, :response_type, "ephemeral")) do
      :ok -> :ok
      error -> Logger.error("Replying to /salamendar failed: #{inspect(error)}")
    end

    :ok
  end
end
