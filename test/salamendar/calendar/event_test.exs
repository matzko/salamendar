defmodule Salamendar.Calendar.EventTest do
  use Salamendar.DataCase, async: true

  alias Salamendar.Accounts
  alias Salamendar.Calendar.Event
  alias Salamendar.Channels.Channel

  @timed %{
    title: "Standup",
    time_zone: "America/Chicago",
    starts_at: ~U[2026-10-10 14:00:00.000000Z],
    ends_at: ~U[2026-10-10 14:15:00.000000Z]
  }

  @all_day %{
    title: "Offsite",
    time_zone: "America/Chicago",
    all_day: true,
    start_date: ~D[2026-10-10],
    end_date: ~D[2026-10-11]
  }

  defp changeset(attrs), do: Event.changeset(%Event{slack_team_id: "T1"}, attrs)

  describe "changeset/2" do
    test "accepts a timed event" do
      assert changeset(@timed).valid?
    end

    test "accepts an all-day event" do
      assert changeset(@all_day).valid?
    end

    test "rejects dates on a timed event" do
      changeset = changeset(Map.put(@timed, :start_date, ~D[2026-10-10]))
      assert %{start_date: ["must be blank for timed events"]} = errors_on(changeset)
    end

    test "rejects timestamps on an all-day event" do
      changeset = changeset(Map.put(@all_day, :ends_at, ~U[2026-10-10 14:00:00.000000Z]))
      assert %{ends_at: ["must be blank for all-day events"]} = errors_on(changeset)
    end

    test "requires the fields for its shape" do
      assert %{starts_at: ["can't be blank"]} =
               errors_on(changeset(Map.delete(@timed, :starts_at)))

      assert %{end_date: ["can't be blank"]} =
               errors_on(changeset(Map.delete(@all_day, :end_date)))
    end

    test "rejects an end at or before the start" do
      changeset = changeset(%{@timed | ends_at: @timed.starts_at})
      assert %{ends_at: ["must be after the start"]} = errors_on(changeset)

      changeset = changeset(%{@all_day | end_date: ~D[2026-10-09]})
      assert %{end_date: ["must be after the start"]} = errors_on(changeset)
    end

    test "rejects an invalid time zone" do
      changeset = changeset(%{@timed | time_zone: "Mars/Olympus_Mons"})
      assert %{time_zone: ["is not a valid time zone"]} = errors_on(changeset)
    end

    test "limits the title length" do
      changeset = changeset(%{@timed | title: String.duplicate("a", 256)})
      assert %{title: [_]} = errors_on(changeset)
    end
  end

  describe "events_time_shape constraint" do
    test "rejects a mixed row that skips the changeset" do
      row = %{
        id: Ecto.UUID.generate(),
        slack_team_id: "T1",
        title: "Mixed",
        time_zone: "UTC",
        all_day: false,
        starts_at: ~U[2026-10-10 14:00:00.000000Z],
        ends_at: ~U[2026-10-10 15:00:00.000000Z],
        start_date: ~D[2026-10-10],
        inserted_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      }

      assert_raise Postgrex.Error, ~r/events_time_shape/, fn ->
        Repo.insert_all(Event, [row])
      end
    end
  end

  describe "cascades" do
    setup do
      {:ok, owner} = Accounts.get_or_create_user("T1", "U1")
      channel = Repo.insert!(%Channel{slack_team_id: "T1", slack_channel_id: "C1"})

      event =
        %Event{slack_team_id: "T1", owner_id: owner.id}
        |> Event.changeset(@timed)
        |> put_assoc(:channels, [channel])
        |> Repo.insert!()

      %{owner: owner, channel: channel, event: event}
    end

    test "deleting an event removes its event_channels rows", %{event: event} do
      assert Repo.aggregate("event_channels", :count) == 1
      Repo.delete!(event)
      assert Repo.aggregate("event_channels", :count) == 0
    end

    test "deleting a user keeps their events with no owner", %{owner: owner, event: event} do
      Repo.delete!(owner)
      assert Repo.reload!(event).owner_id == nil
    end

    test "changing channels replaces the join rows", %{event: event} do
      other = Repo.insert!(%Channel{slack_team_id: "T1", slack_channel_id: "C2"})

      event
      |> Repo.preload(:channels)
      |> change()
      |> put_assoc(:channels, [other])
      |> Repo.update!()

      assert [%{id: id}] = Repo.preload(Repo.reload!(event), :channels).channels
      assert id == other.id
    end
  end
end
