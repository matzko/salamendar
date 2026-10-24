defmodule SalamendarWeb.CalendarLiveTest do
  use SalamendarWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Salamendar.{Accounts, Calendar, Channels, Repo}
  alias Salamendar.Calendar.Changes

  # The week of Oct 11, 2026 as a browser in Chicago asks for it.
  @week %{
    "start" => "2026-10-11T05:00:00.000Z",
    "end" => "2026-10-18T05:00:00.000Z",
    "start_date" => "2026-10-11",
    "end_date" => "2026-10-18"
  }

  defp user!(slack_user_id, attrs) do
    {:ok, user} = Accounts.get_or_create_user("TCL1", slack_user_id, attrs)
    user
  end

  defp channel!(slack_channel_id, members, attrs \\ %{}) do
    {:ok, channel} =
      Channels.upsert_channel(
        "TCL1",
        slack_channel_id,
        Map.merge(%{name: slack_channel_id}, attrs)
      )

    {:ok, channel} = Channels.enable_calendar(channel)
    {:ok, channel} = Channels.update_settings(channel, attrs)
    for member <- members, do: :ok = Channels.add_member(channel, member)
    channel
  end

  defp event!(owner, title, channels) do
    attrs = %{
      title: title,
      time_zone: "America/Chicago",
      all_day: true,
      start_date: ~D[2026-10-12],
      end_date: ~D[2026-10-13]
    }

    {:ok, event, _} = Calendar.create_event(owner, attrs, channels)
    event
  end

  defp fetch(view, params \\ @week) do
    render_hook(view, "fetch", params)
    assert_reply(view, %{events: events})
    events |> Enum.map(& &1.title) |> Enum.sort()
  end

  setup %{conn: conn} do
    viewer = user!("U1", %{name: "Ada"})
    owner = user!("U2", %{name: "Grace"})
    team = channel!("C1", [viewer, owner], %{name: "team"})
    eng = channel!("C2", [viewer, owner], %{name: "eng", week_start: 1})
    %{conn: sign_in(conn, viewer), viewer: viewer, owner: owner, team: team, eng: eng}
  end

  test "renders the calendar and the viewer's channels", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/")

    assert html =~ ~s(phx-hook="Calendar")
    assert has_element?(view, "#calendar[phx-update=ignore]")
    assert has_element?(view, ".calendar-option", "#team")
    assert has_element?(view, ".calendar-option", "#eng")
    assert html =~ "Ada"
  end

  test "fetch replies with the events the viewer can see", %{conn: conn, owner: owner, team: team} do
    private = channel!("C3", [owner], %{name: "secret", is_private: true})
    event!(owner, "Team offsite", [team])
    event!(owner, "Secret", [private])

    {:ok, view, _html} = live(conn, ~p"/")

    assert fetch(view) == ["Team offsite"]
  end

  test "fetch rejects bad and oversized ranges", %{conn: conn, owner: owner, team: team} do
    event!(owner, "Team offsite", [team])
    {:ok, view, _html} = live(conn, ~p"/")

    assert fetch(view, %{"start" => "nope"}) == []
    assert fetch(view, %{@week | "end_date" => "2026-10-10"}) == []

    assert fetch(view, %{@week | "end" => "2027-10-18T05:00:00.000Z", "end_date" => "2027-10-18"}) ==
             []
  end

  test "unchecking a channel hides its events and asks for a refetch", %{
    conn: conn,
    owner: owner,
    team: team,
    eng: eng
  } do
    event!(owner, "Team offsite", [team])
    event!(owner, "Eng sync", [eng])
    {:ok, view, _html} = live(conn, ~p"/")

    view |> element("input[phx-value-id='#{eng.id}']") |> render_click()
    assert_push_event(view, "refetch", %{})

    assert fetch(view) == ["Team offsite"]

    view |> element("input[phx-value-id='#{eng.id}']") |> render_click()
    assert fetch(view) == ["Eng sync", "Team offsite"]
  end

  test "\"My events\" toggles the viewer's own events elsewhere", %{
    conn: conn,
    viewer: viewer,
    team: team
  } do
    left = channel!("C4", [viewer])
    event!(viewer, "Mine", [left])
    :ok = Channels.remove_member(left, viewer)
    event!(viewer, "Mine in team", [team])
    {:ok, view, _html} = live(conn, ~p"/")

    assert fetch(view) == ["Mine", "Mine in team"]

    view |> element("input[phx-click=toggle_own]") |> render_click()
    assert_push_event(view, "refetch", %{})
    assert fetch(view) == ["Mine in team"]
  end

  test "?channel= focuses one channel and uses its week start", %{
    conn: conn,
    owner: owner,
    team: team,
    eng: eng
  } do
    event!(owner, "Team offsite", [team])
    event!(owner, "Eng sync", [eng])

    {:ok, view, _html} = live(conn, ~p"/?channel=C2")

    assert fetch(view) == ["Eng sync"]
    assert has_element?(view, "#calendar[data-week-start='1']")
    refute has_element?(view, "input[phx-value-id='#{team.id}'][checked]")
  end

  test "ignores ?channel= for a channel the viewer isn't in", %{conn: conn, owner: owner} do
    channel!("C5", [owner])
    {:ok, view, _html} = live(conn, ~p"/?channel=C5")

    assert has_element?(view, "input[phx-click=toggle_own][checked]")
  end

  test "toggle_channel ignores channels not in the sidebar", %{conn: conn, owner: owner} do
    private = channel!("C3", [owner], %{is_private: true})
    {:ok, view, _html} = live(conn, ~p"/")

    render_hook(view, "toggle_channel", %{"id" => private.id})
    refute_push_event(view, "refetch", %{})
  end

  test "a change in one of the viewer's channels asks for a refetch", %{conn: conn, team: team} do
    {:ok, view, _html} = live(conn, ~p"/")

    Task.await(Task.async(fn -> Changes.broadcast([team.id], nil) end))
    assert_push_event(view, "refetch", %{})
  end

  test "a change to the viewer's own event elsewhere asks for a refetch", %{
    conn: conn,
    viewer: viewer,
    owner: owner
  } do
    elsewhere = channel!("C6", [owner])
    {:ok, view, _html} = live(conn, ~p"/")

    Task.await(Task.async(fn -> Changes.broadcast([elsewhere.id], viewer.id) end))
    assert_push_event(view, "refetch", %{})
  end

  test "changes elsewhere don't ask for a refetch", %{conn: conn, owner: owner} do
    elsewhere = channel!("C6", [owner])
    {:ok, view, _html} = live(conn, ~p"/")

    Task.await(Task.async(fn -> Changes.broadcast([elsewhere.id], owner.id) end))
    # The broadcast was sent before `render/1` asks the LiveView for its
    # HTML, so the LiveView has handled it by the time `render/1` returns.
    render(view)
    refute_push_event(view, "refetch", %{})
  end

  test "sends visitors without a session to the expired page" do
    assert {:error, {:redirect, %{to: "/auth/expired"}}} = live(build_conn(), ~p"/")
  end

  test "sends a deleted user to the expired page", %{conn: conn, viewer: viewer} do
    Repo.delete!(viewer)
    assert {:error, {:redirect, %{to: "/auth/expired"}}} = live(conn, ~p"/")
  end

  test "pages send no Referer", %{conn: conn} do
    assert get_resp_header(get(conn, ~p"/"), "referrer-policy") == ["no-referrer"]
  end
end
