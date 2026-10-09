defmodule Salamendar.CalendarTest do
  use Salamendar.DataCase, async: true

  alias Salamendar.Accounts
  alias Salamendar.Calendar
  alias Salamendar.Calendar.Event
  alias Salamendar.Channels

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

    {:ok, channel} =
      channel |> Channels.Channel.changeset(%{time_zone: opts[:time_zone]}) |> Repo.update()

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

  defp titles(events), do: Enum.map(events, & &1.title)

  defp day(date), do: Date.range(date, date)

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

      {:ok, disabled, _} = Channels.disable_calendar(channel!("C1"))
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
      {:ok, _, _} = Channels.disable_calendar(channel)

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
      {:ok, _, _} = Channels.disable_calendar(a)

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

  describe "list_channel_events/2" do
    setup do
      %{owner: user!("U1"), channel: channel!("C1", time_zone: "Etc/UTC")}
    end

    test "excludes timed events that only touch the window's edges",
         %{owner: owner, channel: channel} do
      event!(owner, timed(~U[2026-10-09 23:00:00Z], ~U[2026-10-10 00:00:00Z], "Ends at start"), [
        channel
      ])

      event!(owner, timed(~U[2026-10-11 00:00:00Z], ~U[2026-10-11 01:00:00Z], "Starts at end"), [
        channel
      ])

      event!(owner, timed(~U[2026-10-09 23:59:00Z], ~U[2026-10-10 00:01:00Z], "Crosses start"), [
        channel
      ])

      event!(owner, timed(~U[2026-10-10 23:59:00Z], ~U[2026-10-11 00:01:00Z], "Crosses end"), [
        channel
      ])

      assert titles(Calendar.list_channel_events(channel, day(~D[2026-10-10]))) ==
               ["Crosses start", "Crosses end"]
    end

    test "excludes all-day events that only touch the window's edges",
         %{owner: owner, channel: channel} do
      event!(owner, all_day(~D[2026-10-09], ~D[2026-10-10], "Day before"), [channel])
      event!(owner, all_day(~D[2026-10-11], ~D[2026-10-12], "Day after"), [channel])
      event!(owner, all_day(~D[2026-10-08], ~D[2026-10-13], "Spans it"), [channel])

      assert titles(Calendar.list_channel_events(channel, day(~D[2026-10-10]))) == ["Spans it"]
    end

    test "takes days in the channel's time zone", %{owner: owner} do
      tokyo = channel!("C2", time_zone: "Asia/Tokyo")
      # 08:30 on Oct 11 in Tokyo.
      event!(owner, timed(~U[2026-10-10 23:30:00Z], ~U[2026-10-11 00:00:00Z]), [tokyo])

      assert Calendar.list_channel_events(tokyo, day(~D[2026-10-10])) == []
      assert [_] = Calendar.list_channel_events(tokyo, day(~D[2026-10-11]))
    end

    test "covers a multi-day range and only this channel", %{owner: owner, channel: channel} do
      other = channel!("C2")
      event!(owner, timed(~U[2026-10-01 09:00:00Z], ~U[2026-10-01 10:00:00Z], "First"), [channel])
      event!(owner, timed(~U[2026-10-31 09:00:00Z], ~U[2026-10-31 10:00:00Z], "Last"), [channel])
      event!(owner, timed(~U[2026-11-01 09:00:00Z], ~U[2026-11-01 10:00:00Z], "Next"), [channel])
      event!(owner, timed(~U[2026-10-15 09:00:00Z], ~U[2026-10-15 10:00:00Z], "Other"), [other])

      assert titles(
               Calendar.list_channel_events(channel, Date.range(~D[2026-10-01], ~D[2026-10-31]))
             ) == ["First", "Last"]
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
      {:ok, _, _} = Channels.disable_calendar(disabled)

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
end
