defmodule SalamendarWeb.CalendarLiveTest do
  use SalamendarWeb.ConnCase, async: true
  use Oban.Testing, repo: Salamendar.Repo

  import Phoenix.LiveViewTest

  alias Salamendar.{Accounts, Calendar, Channels, Labels, Repo}
  alias Salamendar.Calendar.{Changes, Event}
  alias Salamendar.Workers.PublishHome

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

  test "the sidebar's legend lists the viewer's labels", %{
    conn: conn,
    viewer: viewer,
    owner: owner
  } do
    {:ok, view, _html} = live(conn, ~p"/")
    assert has_element?(view, ".label-legend", "Make labels in Settings")

    {:ok, _} = Labels.create_label(viewer, %{name: "On call", color: "red"}, :personal)
    {:ok, _} = Labels.create_label(owner, %{name: "Holiday", color: "green"}, :shared)
    {:ok, _} = Labels.create_label(owner, %{name: "Theirs", color: "blue"}, :personal)

    {:ok, view, _html} = live(conn, ~p"/")
    assert view |> element(".label-legend") |> render() =~ ~r/Shared.*Holiday.*Mine.*On call/s
    refute has_element?(view, ".label-legend", "Theirs")
    refute has_element?(view, ".label-legend", "Make labels in Settings")
  end

  test "fetch colors events by their label", %{conn: conn, owner: owner, team: team} do
    {:ok, label} = Labels.create_label(owner, %{name: "Holiday", color: "green"}, :shared)

    {:ok, _, _} =
      Calendar.create_event(
        owner,
        %{
          title: "Day off",
          time_zone: "America/Chicago",
          all_day: true,
          start_date: ~D[2026-10-12],
          end_date: ~D[2026-10-13],
          label_id: label.id
        },
        [team]
      )

    {:ok, view, _html} = live(conn, ~p"/")
    render_hook(view, "fetch", @week)
    assert_reply(view, %{events: [event]})
    assert %{backgroundColor: "#0b8043", extendedProps: %{label: "Holiday"}} = event
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

  describe "reschedule" do
    defp reschedule(view, params) do
      render_hook(view, "reschedule", params)
      assert_reply(view, reply)
      reply
    end

    test "moves the owner's timed event and tells everyone", %{
      conn: conn,
      viewer: viewer,
      team: team
    } do
      {:ok, event, _} =
        Calendar.create_event(
          viewer,
          %{
            title: "Standup",
            time_zone: "America/Chicago",
            starts_at: ~U[2026-10-14 14:00:00Z],
            ends_at: ~U[2026-10-14 14:15:00Z]
          },
          [team]
        )

      {:ok, view, _html} = live(conn, ~p"/")

      assert %{ok: true} =
               reschedule(view, %{
                 "id" => event.id,
                 "start" => "2026-10-15T15:00:00.000Z",
                 "end" => "2026-10-15T15:30:00.000Z"
               })

      assert %Event{
               starts_at: ~U[2026-10-15 15:00:00.000000Z],
               ends_at: ~U[2026-10-15 15:30:00.000000Z]
             } =
               Repo.reload!(event)

      # The broadcast reaches this LiveView too.
      assert_push_event(view, "refetch", %{})
      assert_enqueued(worker: PublishHome, args: %{team_id: "TCL1", slack_user_id: "U1"})
    end

    test "moves an all-day event by dates", %{conn: conn, viewer: viewer, team: team} do
      event = event!(viewer, "Offsite", [team])
      {:ok, view, _html} = live(conn, ~p"/")

      assert %{ok: true} =
               reschedule(view, %{
                 "id" => event.id,
                 "start" => "2026-10-14",
                 "end" => "2026-10-16"
               })

      assert %Event{start_date: ~D[2026-10-14], end_date: ~D[2026-10-16]} = Repo.reload!(event)
    end

    test "refuses someone else's event", %{conn: conn, owner: owner, team: team} do
      event = event!(owner, "Team offsite", [team])
      {:ok, view, _html} = live(conn, ~p"/")

      assert %{ok: false} =
               reschedule(view, %{
                 "id" => event.id,
                 "start" => "2026-10-14",
                 "end" => "2026-10-15"
               })

      assert Repo.reload!(event).start_date == ~D[2026-10-12]
      assert render(view) =~ "Only the owner can move this event."
      refute_enqueued(worker: PublishHome)
    end

    test "refuses unknown events and bad times", %{conn: conn, viewer: viewer, team: team} do
      event = event!(viewer, "Offsite", [team])
      {:ok, view, _html} = live(conn, ~p"/")

      assert %{ok: false} =
               reschedule(view, %{"id" => "nope", "start" => "2026-10-14", "end" => "2026-10-15"})

      assert render(view) =~ "This event was deleted."

      # Instants for an all-day event, garbage, a backwards range, missing keys.
      for params <- [
            %{"start" => "2026-10-14T15:00:00Z", "end" => "2026-10-14T16:00:00Z"},
            %{"start" => "soon", "end" => "later"},
            %{"start" => "2026-10-14", "end" => "2026-10-14"},
            %{}
          ] do
        assert %{ok: false} = reschedule(view, Map.put(params, "id", event.id))
      end

      assert render(view) =~ "Couldn&#39;t move this event."
      assert Repo.reload!(event).start_date == ~D[2026-10-12]
    end
  end

  describe "the event panel" do
    defp open(view, event), do: render_hook(view, "open", %{"id" => event.id})

    test "shows someone else's event read-only", %{conn: conn, owner: owner, team: team} do
      private = channel!("C3", [owner], %{name: "secret", is_private: true})

      {:ok, event, _} =
        Calendar.create_event(
          owner,
          %{
            title: "Standup",
            description: "Bring updates",
            time_zone: "America/Chicago",
            starts_at: ~U[2026-10-14 14:00:00Z],
            ends_at: ~U[2026-10-14 14:15:00Z]
          },
          [team, private]
        )

      {:ok, view, _html} =
        conn |> put_connect_params(%{"timeZone" => "America/Chicago"}) |> live(~p"/")

      refute has_element?(view, "#event-panel")
      open(view, event)

      assert has_element?(view, "#event-panel-title", "Standup")
      assert has_element?(view, ".event-when", "Wed, Oct 14, 2026, 9:00 AM – 9:15 AM")
      assert has_element?(view, ".event-owner", "Grace")
      assert has_element?(view, ".event-description", "Bring updates")
      # The private channel the viewer isn't in isn't named.
      assert view |> element(".event-channels") |> render() =~ ~r/>\s*#team\s*</
      refute has_element?(view, "#event-panel form")
      refute has_element?(view, "#event-panel button", "Save")
    end

    test "shows the viewer's own event as theirs", %{conn: conn, viewer: viewer, team: team} do
      event = event!(viewer, "Offsite", [team])
      {:ok, view, _html} = live(conn, ~p"/")

      open(view, event)
      assert has_element?(view, ".event-owner", "You")
      assert has_element?(view, ".event-when", "Mon, Oct 12, 2026")
      refute has_element?(view, ".event-label")
    end

    test "shows the event's label", %{conn: conn, viewer: viewer, team: team} do
      {:ok, label} = Labels.create_label(viewer, %{name: "On call", color: "red"}, :personal)
      event = event!(viewer, "Offsite", [team])
      {:ok, event, _} = Calendar.update_event(viewer, event, %{label_id: label.id}, [team])
      {:ok, view, _html} = live(conn, ~p"/")

      open(view, event)
      assert has_element?(view, ".event-label", "On call")
      assert has_element?(view, ".event-panel-header .swatch[style*='#d50000']")
    end

    test "doesn't open an event the viewer can't see", %{conn: conn, owner: owner} do
      private = channel!("C3", [owner], %{is_private: true})
      event = event!(owner, "Secret", [private])
      {:ok, view, _html} = live(conn, ~p"/")

      open(view, event)
      refute has_element?(view, "#event-panel")

      render_hook(view, "open", %{"id" => "nope"})
      refute has_element?(view, "#event-panel")
    end

    test "closes with the close button or Escape", %{conn: conn, owner: owner, team: team} do
      event = event!(owner, "Team offsite", [team])
      {:ok, view, _html} = live(conn, ~p"/")

      open(view, event)
      view |> element(".event-panel-close") |> render_click()
      refute has_element?(view, "#event-panel")

      open(view, event)
      view |> element("#event-panel") |> render_keydown(%{"key" => "Escape"})
      refute has_element?(view, "#event-panel")
    end

    test "follows changes to the open event, closing when it's deleted", %{
      conn: conn,
      owner: owner,
      team: team
    } do
      event = event!(owner, "Team offsite", [team])
      {:ok, view, _html} = live(conn, ~p"/")
      open(view, event)

      {:ok, event, ids} = Calendar.update_event(owner, event, %{title: "Moved offsite"}, [team])
      Changes.broadcast(ids, owner.id)
      assert has_element?(view, "#event-panel-title", "Moved offsite")

      {:ok, _, ids} = Calendar.delete_event(owner, event)
      Changes.broadcast(ids, owner.id)
      refute has_element?(view, "#event-panel")
    end
  end

  describe "adding and editing in the panel" do
    defp chicago(conn),
      do: conn |> put_connect_params(%{"timeZone" => "America/Chicago"}) |> live(~p"/")

    test "Add event creates a timed event in the browser's zone", %{
      conn: conn,
      viewer: viewer,
      team: team
    } do
      {:ok, view, _html} = chicago(conn)

      view |> element("button.add-event") |> render_click()
      assert has_element?(view, "#event-panel-title", "Add event")
      assert has_element?(view, "#event-form input[type=datetime-local]")
      assert has_element?(view, "#event_title-emoji[phx-hook=EmojiInput] input#event_title")

      assert has_element?(
               view,
               "#event_description-emoji[phx-hook=EmojiInput] textarea#event_description"
             )

      view
      |> form("#event-form",
        event: %{
          title: "Review",
          starts_at: "2026-10-14T13:00",
          ends_at: "2026-10-14T14:00",
          channel_ids: [team.id]
        }
      )
      |> render_submit()

      assert [event] = Repo.all(Event)
      assert event.owner_id == viewer.id
      assert event.starts_at == ~U[2026-10-14 18:00:00.000000Z]
      assert event.time_zone == "America/Chicago"
      assert is_nil(event.description)

      # The panel shows what was saved, and everyone's calendars refetch.
      assert has_element?(view, "#event-panel-title", "Review")
      refute has_element?(view, "#event-form")
      assert_push_event(view, "refetch", %{})
      assert_enqueued(worker: PublishHome, args: %{slack_user_id: "U1"})
    end

    test "selecting days in the month grid starts an all-day event", %{conn: conn, team: team} do
      {:ok, view, _html} = chicago(conn)

      render_hook(view, "new", %{
        "all_day" => true,
        "start" => "2026-10-12T05:00:00.000Z",
        "end" => "2026-10-15T05:00:00.000Z",
        "start_date" => "2026-10-12",
        "end_date" => "2026-10-15"
      })

      assert has_element?(view, "#event_start_date[value='2026-10-12']")
      assert has_element?(view, "#event_end_date[value='2026-10-14']")

      view
      |> form("#event-form", event: %{title: "Offsite", channel_ids: [team.id]})
      |> render_submit()

      assert [%Event{all_day: true, start_date: ~D[2026-10-12], end_date: ~D[2026-10-15]}] =
               Repo.all(Event)
    end

    test "the All day checkbox swaps the inputs, keeping both kinds of times", %{conn: conn} do
      {:ok, view, _html} = chicago(conn)
      view |> element("button.add-event") |> render_click()

      view |> form("#event-form", event: %{all_day: "true"}) |> render_change()
      assert has_element?(view, "#event-form input[type=date]")
      refute has_element?(view, "#event-form input[type=datetime-local]")
      assert has_element?(view, "#event-form input[type=hidden][name='event[starts_at]']")

      view |> form("#event-form", event: %{all_day: "false"}) |> render_change()
      assert has_element?(view, "#event-form input[type=datetime-local]")
    end

    test "shows errors on their fields and saves nothing", %{conn: conn, team: team} do
      {:ok, view, _html} = chicago(conn)
      view |> element("button.add-event") |> render_click()

      # Nothing checked: the checkgroup's hidden "" is all that's sent, as
      # from a browser.
      view
      |> form("#event-form",
        event: %{title: "Nowhere", starts_at: "2026-10-14T13:00", ends_at: "2026-10-14T14:00"}
      )
      |> render_submit()

      assert has_element?(
               view,
               "#event_channel_ids .field-error",
               "must include at least one channel"
             )

      html =
        view
        |> form("#event-form",
          event: %{
            title: "Backwards",
            starts_at: "2026-10-14T14:00",
            ends_at: "2026-10-14T13:00",
            channel_ids: [team.id]
          }
        )
        |> render_submit()

      assert html =~ "must be after the start"
      assert has_element?(view, "#event_ends_at.field-input-error")

      assert Repo.aggregate(Event, :count) == 0
      refute_enqueued(worker: PublishHome)
    end

    test "the owner edits from the details view, keeping the event's zone", %{
      conn: conn,
      viewer: viewer,
      team: team,
      eng: eng
    } do
      {:ok, event, _} =
        Calendar.create_event(
          viewer,
          %{
            title: "Standup",
            time_zone: "Europe/Paris",
            starts_at: ~U[2026-10-14 14:00:00Z],
            ends_at: ~U[2026-10-14 14:15:00Z]
          },
          [team]
        )

      {:ok, view, _html} = chicago(conn)
      render_hook(view, "open", %{"id" => event.id})
      view |> element("#event-panel button", "Edit") |> render_click()

      assert has_element?(view, "#event-panel-title", "Edit event")
      assert has_element?(view, "#event_title[value='Standup']")
      assert has_element?(view, "#event_starts_at[value='2026-10-14T09:00']")

      view
      |> form("#event-form",
        event: %{title: "Sync", ends_at: "2026-10-14T09:30", channel_ids: [team.id, eng.id]}
      )
      |> render_submit()

      event = Repo.reload!(event) |> Repo.preload(:channels)
      assert event.title == "Sync"
      assert event.ends_at == ~U[2026-10-14 14:30:00.000000Z]
      assert event.time_zone == "Europe/Paris"
      assert Enum.sort(Enum.map(event.channels, & &1.id)) == Enum.sort([team.id, eng.id])
      assert has_element?(view, "#event-panel-title", "Sync")
    end

    test "the label picker sets and clears an event's label", %{
      conn: conn,
      viewer: viewer,
      owner: owner,
      team: team
    } do
      {:ok, mine} = Labels.create_label(viewer, %{name: "On call", color: "red"}, :personal)
      {:ok, ours} = Labels.create_label(owner, %{name: "Holiday", color: "green"}, :shared)
      {:ok, _} = Labels.create_label(owner, %{name: "Theirs", color: "blue"}, :personal)
      event = event!(viewer, "Offsite", [team])

      {:ok, view, _html} = chicago(conn)
      render_hook(view, "open", %{"id" => event.id})
      view |> element("#event-panel button", "Edit") |> render_click()

      assert has_element?(view, "#event_label_id option[value='']", "None")

      assert has_element?(
               view,
               "#event_label_id optgroup[label=Shared] option",
               "Holiday · Green"
             )

      assert has_element?(view, "#event_label_id optgroup[label=Mine] option", "On call · Red")
      refute has_element?(view, "#event_label_id option", "Theirs")
      refute has_element?(view, ".label-picker .swatch")

      # Choosing a label shows its color before saving.
      view |> form("#event-form", event: %{label_id: mine.id}) |> render_change()
      assert has_element?(view, ".label-picker .swatch[style*='#d50000']")

      view |> form("#event-form", event: %{label_id: ours.id}) |> render_submit()

      assert Repo.reload!(event).label_id == ours.id
      assert has_element?(view, ".event-label", "Holiday")

      view |> element("#event-panel button", "Edit") |> render_click()
      assert has_element?(view, "#event_label_id option[selected]", "Holiday")

      view |> form("#event-form", event: %{label_id: ""}) |> render_submit()
      assert Repo.reload!(event).label_id == nil
    end

    test "someone else's personal label is refused on the field", %{
      conn: conn,
      viewer: viewer,
      owner: owner,
      team: team
    } do
      {:ok, theirs} = Labels.create_label(owner, %{name: "Theirs", color: "blue"}, :personal)
      event = event!(viewer, "Offsite", [team])

      {:ok, view, _html} = chicago(conn)
      render_hook(view, "open", %{"id" => event.id})
      view |> element("#event-panel button", "Edit") |> render_click()

      # Not an option, so as a forged submission.
      html =
        view |> element("#event-form") |> render_submit(%{event: %{label_id: theirs.id}})

      assert html =~ "is not a label you can use"
      assert has_element?(view, "#event_label_id.field-input-error")
      assert Repo.reload!(event).label_id == nil
    end

    test "Cancel goes back to the details, or closes a new event", %{
      conn: conn,
      viewer: viewer,
      team: team
    } do
      event = event!(viewer, "Offsite", [team])
      {:ok, view, _html} = live(conn, ~p"/")

      render_hook(view, "open", %{"id" => event.id})
      view |> element("#event-panel button", "Edit") |> render_click()
      view |> element("#event-panel button", "Cancel") |> render_click()
      assert has_element?(view, "#event-panel-title", "Offsite")
      refute has_element?(view, "#event-form")

      view |> element("button.add-event") |> render_click()
      view |> element("#event-panel button", "Cancel") |> render_click()
      refute has_element?(view, "#event-panel")
    end

    test "someone else's event can't be edited", %{conn: conn, owner: owner, team: team} do
      event = event!(owner, "Team offsite", [team])
      {:ok, view, _html} = live(conn, ~p"/")

      render_hook(view, "open", %{"id" => event.id})
      refute has_element?(view, "#event-panel button", "Edit")

      render_hook(view, "edit", %{})
      refute has_element?(view, "#event-form")
    end

    test "saving an event deleted meanwhile says so", %{conn: conn, viewer: viewer, team: team} do
      event = event!(viewer, "Offsite", [team])
      {:ok, view, _html} = live(conn, ~p"/")

      render_hook(view, "open", %{"id" => event.id})
      view |> element("#event-panel button", "Edit") |> render_click()
      {:ok, _, _} = Calendar.delete_event(viewer, event)

      html = view |> form("#event-form", event: %{title: "Too late"}) |> render_submit()
      assert html =~ "This event was deleted."
      refute has_element?(view, "#event-panel")
    end
  end

  describe "deleting from the panel" do
    test "the owner deletes after confirming", %{conn: conn, viewer: viewer, team: team} do
      event = event!(viewer, "Offsite", [team])
      {:ok, view, _html} = live(conn, ~p"/")

      render_hook(view, "open", %{"id" => event.id})
      assert has_element?(view, "#event-panel button[data-confirm]", "Delete")

      html = view |> element("#event-panel button", "Delete") |> render_click()

      refute Repo.get(Event, event.id)
      refute has_element?(view, "#event-panel")
      assert html =~ "Deleted “Offsite”."
      assert_push_event(view, "refetch", %{})
      assert_enqueued(worker: PublishHome, args: %{slack_user_id: "U1"})
    end

    test "someone else's event can't be deleted", %{conn: conn, owner: owner, team: team} do
      event = event!(owner, "Team offsite", [team])
      {:ok, view, _html} = live(conn, ~p"/")

      render_hook(view, "open", %{"id" => event.id})
      refute has_element?(view, "#event-panel button", "Delete")

      html = render_hook(view, "delete", %{})
      assert html =~ "Only the event&#39;s owner can delete it."
      assert Repo.get(Event, event.id)
      refute_enqueued(worker: PublishHome)
    end

    test "deleting with no event open does nothing", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      render_hook(view, "delete", %{})
      refute_enqueued(worker: PublishHome)
    end

    test "an event deleted meanwhile says so", %{conn: conn, viewer: viewer, team: team} do
      event = event!(viewer, "Offsite", [team])
      {:ok, view, _html} = live(conn, ~p"/")
      render_hook(view, "open", %{"id" => event.id})

      # Deleted without a broadcast, so the panel is still open.
      Repo.delete!(event)

      html = view |> element("#event-panel button", "Delete") |> render_click()
      assert html =~ "This event was already deleted."
      refute has_element?(view, "#event-panel")
    end
  end

  describe "time zone" do
    test "uses the browser's zone", %{conn: conn} do
      {:ok, view, _html} =
        conn |> put_connect_params(%{"timeZone" => "Pacific/Auckland"}) |> live(~p"/")

      assert view |> element(".time-zone") |> render() =~ "Times in Pacific/Auckland"
    end

    test "falls back to the user's zone for an unknown or missing one", %{
      conn: conn,
      viewer: viewer
    } do
      fallback = "Times in #{Accounts.time_zone(viewer)}"

      {:ok, view, _html} =
        conn |> put_connect_params(%{"timeZone" => "Mars/Olympus"}) |> live(~p"/")

      assert view |> element(".time-zone") |> render() =~ fallback

      {:ok, view, _html} = live(conn, ~p"/")
      assert view |> element(".time-zone") |> render() =~ fallback
    end
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
