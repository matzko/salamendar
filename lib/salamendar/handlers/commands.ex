defmodule Salamendar.Handlers.Commands do
  @moduledoc """
  The `/salamendar` slash command:

    * `enable` / `disable`: turn the channel's calendar on or off.
    * `new`: open the form for a new event.
    * `tz [zone]`: show or set the channel's time zone.
    * `week-start [day]`: show or set the grid's first day of the week.

  Replies go to the command's `response_url` (only the user sees them),
  which works even in a private channel the bot hasn't been invited to.
  Slash commands are acknowledged before this runs, so it can call Slack.
  """

  require Logger

  alias Salamendar.{Channels, SlackAPI}
  alias Salamendar.Channels.Channel
  alias Salamendar.Handlers.{ChannelEvents, EventForm}
  alias Salamendar.Workers.{ReconcileMembers, SyncCanvas}

  @usage """
  *Salamendar* keeps a shared calendar in a channel's canvas.
  • `/salamendar enable`: turn on the calendar in this channel
  • `/salamendar disable`: turn it off (events are kept)
  • `/salamendar new`: add an event
  • `/salamendar tz America/Chicago`: set this channel's time zone
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
      ["tz" | args] -> time_zone(team_id, payload, args)
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
         {:ok, _} <- ReconcileMembers.enqueue(channel.id),
         :ok <- ensure_canvas(channel) do
      {:ok, _} = SyncCanvas.enqueue(channel.id)

      reply(
        payload,
        "The calendar is on! It's in this channel's *Calendar* tab. " <>
          "Add events with `/salamendar new` or from Salamendar's Home tab."
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

  # Creates the canvas tab here, rather than in the sync job, so problems
  # reach the user. Its content is filled in by `SyncCanvas`.
  defp ensure_canvas(channel) do
    {:ok, canvas} = Channels.get_or_create_canvas(channel, :month)

    if canvas.slack_canvas_id do
      :ok
    else
      create_canvas(channel, canvas)
    end
  end

  defp create_canvas(channel, canvas) do
    case SlackAPI.post("canvases.create", %{
           title: "Calendar",
           channel_id: channel.slack_channel_id,
           document_content: %{type: "markdown", markdown: "Loading calendar…"}
         }) do
      {:ok, %{"canvas_id" => canvas_id}} ->
        {:ok, _} = Channels.set_canvas_slack_id(canvas, canvas_id)
        :ok

      {:error, code}
      when code in ["free_team_canvas_tab_already_exists", "channel_canvas_already_exists"] ->
        {:error,
         "This channel already has a canvas tab, and Slack's free plan allows only one. " <>
           "Remove the existing canvas tab, then run `/salamendar enable` again."}

      error ->
        error
    end
  end

  # -- disable --------------------------------------------------------------------

  defp disable(team_id, %{"channel_id" => channel_id} = payload) do
    case Channels.get_channel(team_id, channel_id) do
      %Channel{calendar_enabled: true} = channel ->
        :ok = ChannelEvents.disable(channel)

        reply(
          payload,
          "The calendar is off, and its canvas tab will be removed. Its events are kept: `/salamendar enable` brings them back."
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

  # -- settings -------------------------------------------------------------------

  defp time_zone(team_id, payload, args) do
    with_enabled_channel(team_id, payload, &set_time_zone(&1, payload, args))
  end

  defp set_time_zone(channel, payload, []),
    do: reply(payload, "This channel's calendar uses *#{Channels.time_zone(channel)}*.")

  defp set_time_zone(channel, payload, [zone | _]) do
    case Channels.update_settings(channel, %{time_zone: zone}) do
      {:ok, channel} ->
        {:ok, _} = SyncCanvas.enqueue(channel.id)
        reply(payload, "This channel's calendar now uses *#{zone}*.")

      {:error, _changeset} ->
        reply(
          payload,
          "`#{zone}` isn't a time zone I know. Use a name like `America/Chicago` or `Europe/London`."
        )
    end
  end

  defp week_start(team_id, payload, args) do
    with_enabled_channel(team_id, payload, &set_week_start(&1, payload, args))
  end

  defp set_week_start(channel, payload, []) do
    reply(payload, "This channel's calendar starts weeks on *#{day_name(channel.week_start)}*.")
  end

  defp set_week_start(channel, payload, [day | _]) do
    case parse_weekday(day) do
      {:ok, week_start} ->
        {:ok, channel} = Channels.update_settings(channel, %{week_start: week_start})
        {:ok, _} = SyncCanvas.enqueue(channel.id)
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

  defp reply(%{"response_url" => response_url}, text) do
    case SlackAPI.respond(response_url, %{response_type: "ephemeral", text: text}) do
      :ok -> :ok
      error -> Logger.error("Replying to /salamendar failed: #{inspect(error)}")
    end

    :ok
  end
end
