defmodule Salamendar.Render.HomeTab do
  @moduledoc """
  Block Kit blocks for a user's App Home tab: their events for one day.

  Times are `<!date^…>` tokens, so Slack shows them in each viewer's own
  time zone and format; the fallback text (for clients that can't) uses the
  user's time zone. Events the user owns get an overflow menu with
  Edit and Delete.
  """

  alias Salamendar.Accounts
  alias Salamendar.Accounts.User
  alias Salamendar.Calendar.Event
  alias Salamendar.Render.Period

  @max_blocks 100
  @description_max_length 200

  @doc """
  Action ID of the "Add event" button.
  """
  @spec add_event_action_id() :: String.t()
  def add_event_action_id, do: "add_event"

  @doc """
  Action ID of an owned event's overflow menu. Its option values are
  `"edit:<event id>"` and `"delete:<event id>"`.
  """
  @spec event_menu_action_id() :: String.t()
  def event_menu_action_id, do: "event_menu"

  @doc """
  Blocks for `user`'s Home tab on `date`, showing `events` (e.g. from
  `Calendar.list_user_events_on/2`) in order. Channels are listed when the
  events' `:channels` are preloaded.
  """
  @spec render([Event.t()], User.t(), Date.t()) :: [map()]
  def render(events, %User{} = user, %Date{} = date) do
    time_zone = Accounts.time_zone(user)

    top = [
      %{
        type: "header",
        text: %{type: "plain_text", text: Calendar.strftime(date, "%A, %B %-d"), emoji: true}
      },
      %{
        type: "actions",
        elements: [
          %{
            type: "button",
            action_id: add_event_action_id(),
            style: "primary",
            text: %{type: "plain_text", text: "Add event", emoji: true}
          }
        ]
      },
      %{type: "divider"}
    ]

    top ++ event_blocks(events, user, date, time_zone, @max_blocks - length(top))
  end

  defp event_blocks([], _user, _date, _time_zone, _room) do
    [mrkdwn_section("Nothing on your calendar today. Enjoy! :sunny:")]
  end

  defp event_blocks(events, user, date, time_zone, room) do
    {shown, hidden} =
      if length(events) > room, do: Enum.split(events, room - 1), else: {events, []}

    Enum.map(shown, &event_block(&1, user, date, time_zone)) ++ more_block(length(hidden))
  end

  defp more_block(0), do: []

  defp more_block(count) do
    [%{type: "context", elements: [%{type: "mrkdwn", text: "…and #{count} more"}]}]
  end

  defp event_block(event, user, date, time_zone) do
    lines =
      [
        "*#{escape(event.title)}*",
        when_text(event, date, time_zone),
        channels_text(event),
        description_text(event.description)
      ]
      |> Enum.reject(&is_nil/1)

    section = mrkdwn_section(Enum.join(lines, "\n"))

    if event.owner_id == user.id, do: Map.put(section, :accessory, menu(event)), else: section
  end

  defp when_text(%Event{all_day: true} = event, _date, time_zone) do
    days = Period.local_days(event, time_zone)

    if days.first == days.last,
      do: "All day",
      else: "All day, #{short_date(days.first)} – #{short_date(days.last)}"
  end

  defp when_text(%Event{} = event, date, time_zone) do
    days = Period.local_days(event, time_zone)

    # Show dates only when the event doesn't start and end on this day.
    format = if days.first == date and days.last == date, do: :time, else: :date_time

    "#{date_token(event.starts_at, format, time_zone)} – #{date_token(event.ends_at, format, time_zone)}"
  end

  defp channels_text(%Event{channels: channels}) when is_list(channels) and channels != [] do
    Enum.map_join(channels, " ", &"<##{&1.slack_channel_id}>")
  end

  defp channels_text(_event), do: nil

  defp description_text(nil), do: nil
  defp description_text(""), do: nil

  defp description_text(description) do
    description = String.replace(description, ~r/\s+/, " ")

    if String.length(description) > @description_max_length,
      do: escape(String.slice(description, 0, @description_max_length - 1) <> "…"),
      else: escape(description)
  end

  # https://docs.slack.dev/messaging/formatting-message-text#date-formatting
  defp date_token(datetime, format, time_zone) do
    local = DateTime.shift_zone!(datetime, time_zone)

    {token, fallback} =
      case format do
        :time -> {"{time}", Calendar.strftime(local, "%-I:%M %p")}
        :date_time -> {"{date_short} {time}", Calendar.strftime(local, "%b %-d %-I:%M %p")}
      end

    "<!date^#{DateTime.to_unix(datetime)}^#{token}|#{fallback}>"
  end

  defp short_date(date), do: Calendar.strftime(date, "%b %-d")

  defp menu(event) do
    %{
      type: "overflow",
      action_id: event_menu_action_id(),
      options: [
        option("Edit", "edit:#{event.id}"),
        option("Delete", "delete:#{event.id}")
      ]
    }
  end

  defp option(text, value), do: %{text: %{type: "plain_text", text: text}, value: value}

  defp mrkdwn_section(text), do: %{type: "section", text: %{type: "mrkdwn", text: text}}

  # Slack's mrkdwn treats these three as control characters; escaping them
  # also stops titles from smuggling in `<!channel>` or `<@U…>` mentions.
  defp escape(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end
end
