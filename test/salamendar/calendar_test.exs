defmodule Salamendar.CalendarTest do
  use Salamendar.DataCase, async: true

  alias Salamendar.Accounts
  alias Salamendar.Calendar
  alias Salamendar.Calendar.Event
  alias Salamendar.Channels
  alias Salamendar.Labels

  defp user!(slack_user_id, time_zone \\ "Etc/UTC", team_id \\ "TCA1") do
    {:ok, user} = Accounts.get_or_create_user(team_id, slack_user_id, %{time_zone: time_zone})
    user
  end

  # An enabled channel; `members` are added to it.
  defp channel!(slack_channel_id, opts \\ []) do
    {:ok, channel} =
      Channels.upsert_channel(Keyword.get(opts, :team_id, "TCA1"), slack_channel_id, %{
        is_private: Keyword.get(opts, :private, false)
      })

    {:ok, channel} = Channels.enable_calendar(channel)
    for member <- Keyword.get(opts, :members, []), do: :ok = Channels.add_member(channel, member)
    channel
  end

  defp timed(starts_at, ends_at, title \\ "Timed") do
    %{title: title, time_zone: "Etc/UTC", starts_at: starts_at, ends_at: ends_at}
  end

  defp all_day(start_date, end_date, title \\ "All day") do
    %{
      title: title,
      time_zone: "Etc/UTC",
      all_day: true,
      start_date: start_date,
      end_date: end_date
    }
  end

  defp event!(owner, attrs, channels) do
    {:ok, event, _} = Calendar.create_event(owner, attrs, channels)
    event
  end

  defp label!(user, scope, name \\ "On call") do
    {:ok, label} = Labels.create_label(user, %{name: name, color: "red"}, scope)
    label
  end

  defp titles(events), do: Enum.map(events, & &1.title)

  describe "get_event/1" do
    test "finds an event by ID, and returns nil for unknown or malformed IDs" do
      event =
        event!(user!("U1"), timed(~U[2026-10-10 14:00:00Z], ~U[2026-10-10 15:00:00Z]), [
          channel!("C1")
        ])

      assert Calendar.get_event(event.id).id == event.id
      assert is_nil(Calendar.get_event(Ecto.UUID.generate()))
      assert is_nil(Calendar.get_event("nope"))
      assert is_nil(Calendar.get_event(nil))
    end
  end

  describe "create_event/3" do
    test "creates the event in its channels and returns them as affected" do
      owner = user!("U1")
      a = channel!("C1")
      b = channel!("C2")

      assert {:ok, %Event{} = event, affected} =
               Calendar.create_event(
                 owner,
                 timed(~U[2026-10-10 14:00:00Z], ~U[2026-10-10 15:00:00Z]),
                 [a, b, a]
               )

      assert event.owner_id == owner.id
      assert event.slack_team_id == "TCA1"
      assert Enum.sort(affected) == Enum.sort([a.id, b.id])
      assert Repo.aggregate("event_channels", :count) == 2
    end

    test "returns changeset errors for the event fields" do
      owner = user!("U1")

      assert {:error, changeset} =
               Calendar.create_event(owner, %{title: "", time_zone: "UTC"}, [channel!("C1")])

      assert %{title: ["can't be blank"]} = errors_on(changeset)
    end

    test "requires at least one channel" do
      assert {:error, changeset} =
               Calendar.create_event(
                 user!("U1"),
                 timed(~U[2026-10-10 14:00:00Z], ~U[2026-10-10 15:00:00Z]),
                 []
               )

      assert %{channels: ["must include at least one channel"]} = errors_on(changeset)
    end

    test "rejects channels that are disabled, archived or in another workspace" do
      owner = user!("U1")
      attrs = timed(~U[2026-10-10 14:00:00Z], ~U[2026-10-10 15:00:00Z])

      {:ok, disabled} = Channels.disable_calendar(channel!("C1"))
      {:ok, archived} = Channels.archive_channel(channel!("C2"))
      elsewhere = channel!("C3", team_id: "TCA2")

      for {channel, message} <- [
            {disabled, "must have the calendar enabled"},
            {archived, "must have the calendar enabled"},
            {elsewhere, "must be in your workspace"}
          ] do
        assert {:error, changeset} = Calendar.create_event(owner, attrs, [channel])
        assert %{channels: [^message]} = errors_on(changeset)
      end

      assert Repo.aggregate(Event, :count) == 0
    end

    test "only members can add an event to a private channel" do
      member = user!("U1")
      outsider = user!("U2")
      private = channel!("C1", private: true, members: [member])
      attrs = timed(~U[2026-10-10 14:00:00Z], ~U[2026-10-10 15:00:00Z])

      assert {:error, changeset} = Calendar.create_event(outsider, attrs, [private])
      assert %{channels: ["can only include private channels you're in"]} = errors_on(changeset)

      assert {:ok, _, _} = Calendar.create_event(member, attrs, [private])
    end

    test "checks the stored channel, not the struct passed in" do
      owner = user!("U1")
      channel = channel!("C1")
      {:ok, _} = Channels.disable_calendar(channel)

      assert {:error, _} =
               Calendar.create_event(
                 owner,
                 timed(~U[2026-10-10 14:00:00Z], ~U[2026-10-10 15:00:00Z]),
                 [channel]
               )
    end
  end

  describe "update_event/4" do
    setup do
      owner = user!("U1")
      a = channel!("C1")
      event = event!(owner, timed(~U[2026-10-10 14:00:00Z], ~U[2026-10-10 15:00:00Z]), [a])
      %{owner: owner, a: a, event: event}
    end

    test "moving an event between channels affects both", %{owner: owner, a: a, event: event} do
      b = channel!("C2")

      assert {:ok, event, affected} =
               Calendar.update_event(owner, event, %{title: "Moved"}, [b])

      assert event.title == "Moved"
      assert Enum.sort(affected) == Enum.sort([a.id, b.id])
      assert [%{id: b_id}] = Repo.preload(event, :channels, force: true).channels
      assert b_id == b.id
    end

    test "only the owner can update", %{a: a, event: event} do
      assert {:error, :forbidden} = Calendar.update_event(user!("U2"), event, %{title: "X"}, [a])
      assert Repo.reload!(event).title == "Timed"
    end

    test "returns :not_found for a deleted event", %{owner: owner, a: a, event: event} do
      Repo.delete!(event)
      assert {:error, :not_found} = Calendar.update_event(owner, event, %{}, [a])
    end

    test "returns changeset errors", %{owner: owner, a: a, event: event} do
      assert {:error, changeset} =
               Calendar.update_event(owner, event, %{ends_at: ~U[2026-10-10 13:00:00Z]}, [a])

      assert %{ends_at: ["must be after the start"]} = errors_on(changeset)
    end

    test "a channel the event already has can stay after it's disabled",
         %{owner: owner, a: a, event: event} do
      {:ok, _} = Channels.disable_calendar(a)

      assert {:ok, _, [a_id]} = Calendar.update_event(owner, event, %{title: "Kept"}, [a])
      assert a_id == a.id
    end

    test "removing a private channel needs no membership", %{owner: owner, a: a} do
      private = channel!("C2", private: true, members: [owner])
      event = event!(owner, timed(~U[2026-10-11 14:00:00Z], ~U[2026-10-11 15:00:00Z]), [private])
      :ok = Channels.remove_member(private, owner)

      # Keeping it is fine too: only added channels are checked.
      assert {:ok, _, _} = Calendar.update_event(owner, event, %{}, [private, a])
      assert {:ok, _, affected} = Calendar.update_event(owner, event, %{}, [a])
      assert private.id in affected
    end

    test "adding a private channel needs membership", %{owner: owner, event: event} do
      private = channel!("C2", private: true)

      assert {:error, changeset} = Calendar.update_event(owner, event, %{}, [private])
      assert %{channels: [_]} = errors_on(changeset)
    end
  end

  describe "labels on events" do
    setup do
      owner = user!("U1")
      a = channel!("C1")
      %{owner: owner, a: a, times: timed(~U[2026-10-10 14:00:00Z], ~U[2026-10-10 15:00:00Z])}
    end

    test "an event can have its owner's personal label or a shared one",
         %{owner: owner, a: a, times: times} do
      mine = label!(owner, :personal)
      ours = label!(user!("U2"), :shared, "Holiday")

      assert {:ok, event, _} =
               Calendar.create_event(owner, Map.put(times, :label_id, mine.id), [a])

      assert event.label_id == mine.id

      assert {:ok, event, _} = Calendar.update_event(owner, event, %{label_id: ours.id}, [a])
      assert event.label_id == ours.id

      assert {:ok, event, _} = Calendar.update_event(owner, event, %{label_id: nil}, [a])
      assert event.label_id == nil
    end

    test "not someone else's personal label or another workspace's",
         %{owner: owner, a: a, times: times} do
      theirs = label!(user!("U2"), :personal)
      elsewhere = label!(user!("U3", "Etc/UTC", "TCA2"), :shared)

      for label <- [theirs, elsewhere] do
        assert {:error, changeset} =
                 Calendar.create_event(owner, Map.put(times, :label_id, label.id), [a])

        assert %{label_id: ["is not a label you can use"]} = errors_on(changeset)
      end

      event = event!(owner, times, [a])

      assert {:error, changeset} =
               Calendar.update_event(owner, event, %{label_id: theirs.id}, [a])

      assert %{label_id: ["is not a label you can use"]} = errors_on(changeset)
    end

    test "a deleted label is an error on the field", %{owner: owner, a: a, times: times} do
      label = label!(owner, :personal)
      {:ok, _, _} = Labels.delete_label(owner, label)

      assert {:error, changeset} =
               Calendar.create_event(owner, Map.put(times, :label_id, label.id), [a])

      assert %{label_id: [_]} = errors_on(changeset)
    end

    test "rescheduling leaves the label alone", %{owner: owner, a: a, times: times} do
      label = label!(owner, :personal)
      event = event!(owner, Map.put(times, :label_id, label.id), [a])

      assert {:ok, moved, _} =
               Calendar.reschedule_event(owner, event, %{
                 starts_at: ~U[2026-10-12 16:00:00Z],
                 ends_at: ~U[2026-10-12 18:00:00Z],
                 label_id: nil
               })

      assert moved.label_id == label.id
    end
  end

  describe "owned_event_channel_ids/1" do
    test "the channels of the user's events, once each" do
      owner = user!("U1")
      a = channel!("C1")
      b = channel!("C2")
      c = channel!("C3")
      times = timed(~U[2026-10-10 14:00:00Z], ~U[2026-10-10 15:00:00Z])
      event!(owner, times, [a, b])
      event!(owner, times, [b])
      event!(user!("U2"), times, [c])

      assert Enum.sort(Calendar.owned_event_channel_ids(owner)) == Enum.sort([a.id, b.id])
      assert Calendar.owned_event_channel_ids(user!("U3")) == []
    end
  end

  describe "reschedule_event/3" do
    setup do
      owner = user!("U1")
      a = channel!("C1")
      b = channel!("C2")
      event = event!(owner, timed(~U[2026-10-10 14:00:00Z], ~U[2026-10-10 15:00:00Z]), [a, b])
      %{owner: owner, a: a, b: b, event: event}
    end

    test "moves a timed event by instants, keeping its channels",
         %{owner: owner, a: a, b: b, event: event} do
      assert {:ok, moved, affected} =
               Calendar.reschedule_event(owner, event, %{
                 starts_at: ~U[2026-10-12 16:00:00Z],
                 ends_at: ~U[2026-10-12 18:00:00Z]
               })

      assert moved.starts_at == ~U[2026-10-12 16:00:00.000000Z]
      assert moved.ends_at == ~U[2026-10-12 18:00:00.000000Z]
      refute moved.all_day
      assert Enum.sort(affected) == Enum.sort([a.id, b.id])
      assert Repo.aggregate("event_channels", :count) == 2
    end

    test "moves an all-day event by dates", %{owner: owner, a: a} do
      event = event!(owner, all_day(~D[2026-10-10], ~D[2026-10-11]), [a])

      assert {:ok, moved, [a_id]} =
               Calendar.reschedule_event(owner, event, %{
                 start_date: ~D[2026-10-12],
                 end_date: ~D[2026-10-15]
               })

      assert {moved.start_date, moved.end_date} == {~D[2026-10-12], ~D[2026-10-15]}
      assert moved.all_day
      assert a_id == a.id
    end

    test "changes only the times", %{owner: owner, event: event} do
      assert {:ok, moved, _} =
               Calendar.reschedule_event(owner, event, %{
                 starts_at: ~U[2026-10-12 16:00:00Z],
                 ends_at: ~U[2026-10-12 18:00:00Z],
                 title: "Renamed",
                 time_zone: "America/Chicago",
                 all_day: true
               })

      assert {moved.title, moved.time_zone, moved.all_day} == {"Timed", "Etc/UTC", false}
    end

    test "can't switch a timed event to all-day", %{owner: owner, event: event} do
      assert {:error, changeset} =
               Calendar.reschedule_event(owner, event, %{
                 start_date: ~D[2026-10-12],
                 end_date: ~D[2026-10-13]
               })

      assert %{start_date: ["must be blank for timed events"]} = errors_on(changeset)
    end

    test "can't switch an all-day event to timed", %{owner: owner, a: a} do
      event = event!(owner, all_day(~D[2026-10-10], ~D[2026-10-11]), [a])

      assert {:error, changeset} =
               Calendar.reschedule_event(owner, event, %{
                 starts_at: ~U[2026-10-12 16:00:00Z],
                 ends_at: ~U[2026-10-12 18:00:00Z]
               })

      assert %{starts_at: ["must be blank for all-day events"]} = errors_on(changeset)
    end

    test "rejects an end at or before the start", %{owner: owner, event: event} do
      assert {:error, changeset} =
               Calendar.reschedule_event(owner, event, %{
                 starts_at: ~U[2026-10-12 16:00:00Z],
                 ends_at: ~U[2026-10-12 16:00:00Z]
               })

      assert %{ends_at: ["must be after the start"]} = errors_on(changeset)
    end

    test "stores the instants it's given across the DST change", %{owner: owner, a: a} do
      # 9:00 CDT on Sat Oct 31, dragged to 9:00 CST on Sun Nov 1: 25 hours
      # later, though the browser's `delta` says 24.
      event = event!(owner, timed(~U[2026-10-31 14:00:00Z], ~U[2026-10-31 15:00:00Z]), [a])

      assert {:ok, moved, _} =
               Calendar.reschedule_event(owner, event, %{
                 starts_at: ~U[2026-11-01 15:00:00Z],
                 ends_at: ~U[2026-11-01 16:00:00Z]
               })

      assert DateTime.shift_zone!(moved.starts_at, "America/Chicago").hour == 9
    end

    test "only the owner can reschedule", %{a: a, event: event} do
      other = user!("U2")
      :ok = Channels.add_member(a, other)

      assert {:error, :forbidden} =
               Calendar.reschedule_event(other, event, %{
                 starts_at: ~U[2026-10-12 16:00:00Z],
                 ends_at: ~U[2026-10-12 18:00:00Z]
               })

      assert Repo.reload!(event).starts_at == ~U[2026-10-10 14:00:00.000000Z]
    end

    test "returns :not_found for a deleted event", %{owner: owner, event: event} do
      Repo.delete!(event)
      assert {:error, :not_found} = Calendar.reschedule_event(owner, event, %{})
    end
  end

  describe "delete_event/2" do
    test "the owner can delete, returning the event's channels" do
      owner = user!("U1")
      a = channel!("C1")
      event = event!(owner, timed(~U[2026-10-10 14:00:00Z], ~U[2026-10-10 15:00:00Z]), [a])

      assert {:error, :forbidden} = Calendar.delete_event(user!("U2"), event)
      assert {:ok, _, [a_id]} = Calendar.delete_event(owner, event)
      assert a_id == a.id
      refute Repo.get(Event, event.id)
      assert {:error, :not_found} = Calendar.delete_event(owner, event)
    end
  end

  describe "list_user_events_on/2" do
    test "an all-day event is on the same date in every time zone" do
      owner = user!("U1")
      honolulu = user!("U2", "Pacific/Honolulu")
      tongatapu = user!("U3", "Pacific/Tongatapu")
      channel = channel!("C1", members: [honolulu, tongatapu])
      event!(owner, all_day(~D[2026-10-10], ~D[2026-10-11]), [channel])

      for user <- [honolulu, tongatapu] do
        assert [_] = Calendar.list_user_events_on(user, ~D[2026-10-10])
        assert [] = Calendar.list_user_events_on(user, ~D[2026-10-09])
        assert [] = Calendar.list_user_events_on(user, ~D[2026-10-11])
      end
    end

    test "a timed event falls on each user's local day" do
      owner = user!("U1")
      chicago = user!("U2", "America/Chicago")
      tokyo = user!("U3", "Asia/Tokyo")
      channel = channel!("C1", members: [chicago, tokyo])
      # 18:30 on Oct 10 in Chicago, 08:30 on Oct 11 in Tokyo.
      event!(owner, timed(~U[2026-10-10 23:30:00Z], ~U[2026-10-11 00:00:00Z]), [channel])

      assert [_] = Calendar.list_user_events_on(chicago, ~D[2026-10-10])
      assert [] = Calendar.list_user_events_on(chicago, ~D[2026-10-11])
      assert [] = Calendar.list_user_events_on(tokyo, ~D[2026-10-10])
      assert [_] = Calendar.list_user_events_on(tokyo, ~D[2026-10-11])
    end

    test "shows an event in two of the user's channels once" do
      owner = user!("U1")
      user = user!("U2")
      a = channel!("C1", members: [user])
      b = channel!("C2", members: [user])
      event!(owner, timed(~U[2026-10-10 14:00:00Z], ~U[2026-10-10 15:00:00Z]), [a, b])

      assert [_] = Calendar.list_user_events_on(user, ~D[2026-10-10])
    end

    test "hides disabled, archived and left channels, and other private channels" do
      owner = user!("U1")
      user = user!("U2")
      attrs = &timed(~U[2026-10-10 14:00:00Z], ~U[2026-10-10 15:00:00Z], &1)

      disabled = channel!("C1", members: [user])
      event!(owner, attrs.("Disabled"), [disabled])
      {:ok, _} = Channels.disable_calendar(disabled)

      archived = channel!("C2", members: [user])
      event!(owner, attrs.("Archived"), [archived])
      {:ok, _} = Channels.archive_channel(archived)

      left = channel!("C3", members: [user])
      event!(owner, attrs.("Left"), [left])
      :ok = Channels.remove_member(left, user)

      private = channel!("C4", private: true, members: [owner])
      event!(owner, attrs.("Private"), [private])

      visible = channel!("C5", members: [user])
      event!(owner, attrs.("Visible"), [visible])

      assert titles(Calendar.list_user_events_on(user, ~D[2026-10-10])) == ["Visible"]
    end

    test "owners see their own events after leaving the channel" do
      owner = user!("U1")
      channel = channel!("C1", members: [owner])
      event!(owner, timed(~U[2026-10-10 14:00:00Z], ~U[2026-10-10 15:00:00Z]), [channel])
      :ok = Channels.remove_member(channel, owner)

      assert [_] = Calendar.list_user_events_on(owner, ~D[2026-10-10])
    end

    test "lists all-day events first, then by start time" do
      owner = user!("U1")
      channel = channel!("C1")
      event!(owner, timed(~U[2026-10-10 15:00:00Z], ~U[2026-10-10 16:00:00Z], "Late"), [channel])
      event!(owner, timed(~U[2026-10-10 09:00:00Z], ~U[2026-10-10 10:00:00Z], "Early"), [channel])
      event!(owner, all_day(~D[2026-10-10], ~D[2026-10-11], "All day"), [channel])

      assert titles(Calendar.list_user_events_on(owner, ~D[2026-10-10])) ==
               ["All day", "Early", "Late"]
    end

    test "uses the default time zone for users without one" do
      owner = user!("U1")
      {:ok, stub} = Accounts.get_or_create_user("TCA1", "U2")
      channel = channel!("C1", members: [stub])
      # 23:30 on Oct 9 in Chicago (the test default), Oct 10 in UTC.
      event!(owner, timed(~U[2026-10-10 04:30:00Z], ~U[2026-10-10 05:00:00Z]), [channel])

      assert [_] = Calendar.list_user_events_on(stub, ~D[2026-10-09])
    end

    test "handles days whose midnight is skipped or repeated" do
      owner = user!("U1")
      havana = user!("U2", "America/Havana")
      channel = channel!("C1", members: [havana])
      # Clocks jump from 00:00 to 01:00 (05:00 UTC) on Mar 8, 2026.
      event!(owner, timed(~U[2026-03-08 05:00:00Z], ~U[2026-03-08 05:30:00Z], "Spring"), [
        channel
      ])

      # Midnight happens twice on Nov 1, 2026; the day starts at the first,
      # 04:00 UTC.
      event!(owner, timed(~U[2026-11-01 04:00:00Z], ~U[2026-11-01 04:30:00Z], "Fall"), [channel])

      assert titles(Calendar.list_user_events_on(havana, ~D[2026-03-08])) == ["Spring"]
      assert titles(Calendar.list_user_events_on(havana, ~D[2026-11-01])) == ["Fall"]
      assert [] = Calendar.list_user_events_on(havana, ~D[2026-10-31])
    end
  end

  describe "get_visible_event/2" do
    setup do
      owner = user!("U1")
      viewer = user!("U2")
      %{owner: owner, viewer: viewer, channel: channel!("C1", members: [viewer])}
    end

    defp visible?(viewer, event), do: not is_nil(Calendar.get_visible_event(viewer, event.id))

    test "finds an event in the viewer's channels, with its owner and channels", %{
      owner: owner,
      viewer: viewer,
      channel: channel
    } do
      event = event!(owner, timed(~U[2026-10-12 14:00:00Z], ~U[2026-10-12 15:00:00Z]), [channel])

      assert %Event{} = found = Calendar.get_visible_event(viewer, event.id)
      assert found.owner.id == owner.id
      assert [%{id: channel_id}] = found.channels
      assert channel_id == channel.id
    end

    test "finds the viewer's own events in channels they've left", %{viewer: viewer} do
      left = channel!("C2", members: [viewer])
      event = event!(viewer, timed(~U[2026-10-12 14:00:00Z], ~U[2026-10-12 15:00:00Z]), [left])
      :ok = Channels.remove_member(left, viewer)

      assert visible?(viewer, event)
    end

    test "hides events in channels the viewer isn't in, or that are off or archived", %{
      owner: owner,
      viewer: viewer,
      channel: channel
    } do
      elsewhere = channel!("C2", members: [owner])

      hidden =
        event!(owner, timed(~U[2026-10-12 14:00:00Z], ~U[2026-10-12 15:00:00Z]), [elsewhere])

      refute visible?(viewer, hidden)

      event = event!(owner, timed(~U[2026-10-12 14:00:00Z], ~U[2026-10-12 15:00:00Z]), [channel])
      {:ok, archived} = Channels.archive_channel(channel)
      refute visible?(viewer, event)

      {:ok, unarchived} = Channels.unarchive_channel(archived)
      {:ok, _} = Channels.disable_calendar(unarchived)
      refute visible?(viewer, event)
    end

    test "hides another workspace's events, even the viewer's own ID", %{viewer: viewer} do
      stranger = user!("U9", "Etc/UTC", "TOTHER")
      theirs = channel!("C9", team_id: "TOTHER", members: [stranger])

      event =
        event!(stranger, timed(~U[2026-10-12 14:00:00Z], ~U[2026-10-12 15:00:00Z]), [theirs])

      refute visible?(viewer, event)
    end

    test "returns nil for unknown and malformed IDs", %{viewer: viewer} do
      assert is_nil(Calendar.get_visible_event(viewer, Ecto.UUID.generate()))
      assert is_nil(Calendar.get_visible_event(viewer, "nope"))
      assert is_nil(Calendar.get_visible_event(viewer, nil))
    end
  end

  describe "list_visible_events/4" do
    # The week of Oct 11, 2026 as a browser in Chicago asks for it: local
    # midnights (CDT, UTC-5) and local dates.
    @from {~U[2026-10-11 05:00:00Z], ~D[2026-10-11]}
    @to {~U[2026-10-18 05:00:00Z], ~D[2026-10-18]}

    setup do
      owner = user!("U1")
      viewer = user!("U2")
      %{owner: owner, viewer: viewer, channel: channel!("C1", members: [viewer])}
    end

    test "timed events overlap by instant, excluding ones that only touch the edges", %{
      owner: owner,
      viewer: viewer,
      channel: channel
    } do
      event!(owner, timed(~U[2026-10-11 04:00:00Z], ~U[2026-10-11 05:00:00Z], "Before"), [channel])

      event!(owner, timed(~U[2026-10-11 04:30:00Z], ~U[2026-10-11 05:30:00Z], "Into"), [channel])

      event!(owner, timed(~U[2026-10-18 04:30:00Z], ~U[2026-10-18 05:30:00Z], "Out of"), [channel])

      event!(owner, timed(~U[2026-10-18 05:00:00Z], ~U[2026-10-18 06:00:00Z], "After"), [channel])

      assert titles(Calendar.list_visible_events(viewer, @from, @to)) == ["Into", "Out of"]
    end

    test "all-day events overlap by date, excluding ones that only touch the edges", %{
      owner: owner,
      viewer: viewer,
      channel: channel
    } do
      event!(owner, all_day(~D[2026-10-10], ~D[2026-10-11], "Before"), [channel])
      event!(owner, all_day(~D[2026-10-10], ~D[2026-10-12], "Into"), [channel])
      event!(owner, all_day(~D[2026-10-17], ~D[2026-10-19], "Out of"), [channel])
      event!(owner, all_day(~D[2026-10-18], ~D[2026-10-19], "After"), [channel])

      assert titles(Calendar.list_visible_events(viewer, @from, @to)) == ["Into", "Out of"]
    end

    test "preloads owners and channels", %{owner: owner, viewer: viewer, channel: channel} do
      event!(owner, all_day(~D[2026-10-12], ~D[2026-10-13]), [channel])

      assert [%Event{owner: %Accounts.User{id: owner_id}, channels: [%Channels.Channel{}]}] =
               Calendar.list_visible_events(viewer, @from, @to)

      assert owner_id == owner.id
    end

    test ":channel_ids limits to those channels, plus the user's own events", %{
      owner: owner,
      viewer: viewer,
      channel: channel
    } do
      other = channel!("C2", members: [viewer])
      event!(owner, all_day(~D[2026-10-12], ~D[2026-10-13], "In C1"), [channel])
      event!(owner, all_day(~D[2026-10-12], ~D[2026-10-13], "In C2"), [other])
      event!(viewer, all_day(~D[2026-10-12], ~D[2026-10-13], "Mine in C2"), [other])

      assert titles(Calendar.list_visible_events(viewer, @from, @to, channel_ids: [channel.id])) ==
               ["In C1", "Mine in C2"]

      assert titles(
               Calendar.list_visible_events(viewer, @from, @to,
                 channel_ids: [channel.id],
                 own: false
               )
             ) == ["In C1"]

      assert titles(Calendar.list_visible_events(viewer, @from, @to, channel_ids: [], own: true)) ==
               ["Mine in C2"]
    end

    test ":channel_ids can't reveal channels the user can't see", %{owner: owner, viewer: viewer} do
      private = channel!("C2", private: true, members: [owner])
      event!(owner, all_day(~D[2026-10-12], ~D[2026-10-13]), [private])

      assert [] = Calendar.list_visible_events(viewer, @from, @to, channel_ids: [private.id])
    end

    test "ignores other workspaces" do
      outsider = user!("U3", "Etc/UTC", "TCA2")
      channel = channel!("C9", team_id: "TCA2", members: [outsider])
      event!(outsider, all_day(~D[2026-10-12], ~D[2026-10-13]), [channel])
      viewer = user!("U2")

      assert [] = Calendar.list_visible_events(viewer, @from, @to)
    end
  end
end
