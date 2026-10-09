defmodule Salamendar.Render.HomeTabTest do
  use ExUnit.Case, async: true

  alias Salamendar.Accounts.User
  alias Salamendar.Calendar.Event
  alias Salamendar.Channels.Channel
  alias Salamendar.Render.HomeTab

  @user %User{id: "user-1", time_zone: "America/Chicago"}
  @date ~D[2026-10-09]

  defp timed(attrs) do
    struct!(
      %Event{
        id: "event-1",
        owner_id: "someone-else",
        title: "Standup",
        starts_at: ~U[2026-10-09 14:00:00Z],
        ends_at: ~U[2026-10-09 14:15:00Z]
      },
      attrs
    )
  end

  defp texts(blocks) do
    for %{type: "section", text: %{text: text}} <- blocks, do: text
  end

  test "renders a day's events" do
    events = [
      %Event{
        id: "event-0",
        owner_id: "user-1",
        title: "Offsite",
        all_day: true,
        start_date: ~D[2026-10-08],
        end_date: ~D[2026-10-11],
        channels: [%Channel{slack_channel_id: "C1"}, %Channel{slack_channel_id: "C2"}]
      },
      timed(description: "Daily  sync.\nBring   updates.")
    ]

    assert HomeTab.render(events, @user, @date) == [
             %{
               type: "header",
               text: %{type: "plain_text", text: "Friday, October 9", emoji: true}
             },
             %{
               type: "actions",
               elements: [
                 %{
                   type: "button",
                   action_id: "add_event",
                   style: "primary",
                   text: %{type: "plain_text", text: "Add event", emoji: true}
                 }
               ]
             },
             %{type: "divider"},
             %{
               type: "section",
               text: %{type: "mrkdwn", text: "*Offsite*\nAll day, Oct 8 – Oct 10\n<#C1> <#C2>"},
               accessory: %{
                 type: "overflow",
                 action_id: "event_menu",
                 options: [
                   %{text: %{type: "plain_text", text: "Edit"}, value: "edit:event-0"},
                   %{text: %{type: "plain_text", text: "Delete"}, value: "delete:event-0"}
                 ]
               }
             },
             %{
               type: "section",
               text: %{
                 type: "mrkdwn",
                 text:
                   "*Standup*\n" <>
                     "<!date^1791554400^{time}|9:00 AM> – <!date^1791555300^{time}|9:15 AM>\n" <>
                     "Daily sync. Bring updates."
               }
             }
           ]
  end

  test "has a friendly empty state" do
    assert [_header, _actions, _divider, %{type: "section", text: %{text: text}}] =
             HomeTab.render([], @user, @date)

    assert text =~ "Nothing on your calendar today"
  end

  test "shows dates for timed events that run past the day" do
    event = timed(starts_at: ~U[2026-10-09 22:00:00Z], ends_at: ~U[2026-10-10 07:00:00Z])
    [text] = texts(HomeTab.render([event], @user, @date))

    assert text =~ "{date_short} {time}|Oct 9 5:00 PM>"
    assert text =~ "{date_short} {time}|Oct 10 2:00 AM>"
  end

  test "escapes mrkdwn control characters" do
    [text] = texts(HomeTab.render([timed(title: "<!channel> Q&A")], @user, @date))
    assert text =~ "*&lt;!channel&gt; Q&amp;A*"
  end

  test "truncates long descriptions" do
    [text] = texts(HomeTab.render([timed(description: String.duplicate("a", 300))], @user, @date))
    assert text =~ String.duplicate("a", 199) <> "…"
    refute text =~ String.duplicate("a", 200)
  end

  test "stays within Slack's 100-block limit" do
    events = for i <- 1..150, do: timed(id: "event-#{i}", title: "Event #{i}")
    blocks = HomeTab.render(events, @user, @date)

    assert length(blocks) == 100
    assert %{type: "context", elements: [%{text: "…and 54 more"}]} = List.last(blocks)

    exactly_full = for i <- 1..97, do: timed(id: "event-#{i}", title: "Event #{i}")
    blocks = HomeTab.render(exactly_full, @user, @date)
    assert length(blocks) == 100
    assert %{type: "section"} = List.last(blocks)
  end

  test "uses the default time zone for users without one" do
    [text] = texts(HomeTab.render([timed([])], %User{id: "user-1"}, @date))
    # The test default is America/Chicago.
    assert text =~ "|9:00 AM>"
  end
end
