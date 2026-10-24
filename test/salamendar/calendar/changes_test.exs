defmodule Salamendar.Calendar.ChangesTest do
  use Salamendar.DataCase, async: true

  alias Salamendar.{Accounts, Channels}
  alias Salamendar.Calendar.Changes

  defp user!(slack_user_id) do
    {:ok, user} = Accounts.get_or_create_user("TCC1", slack_user_id)
    user
  end

  defp channel!(slack_channel_id, members, opts \\ []) do
    {:ok, channel} = Channels.upsert_channel("TCC1", slack_channel_id)

    {:ok, channel} =
      if Keyword.get(opts, :enabled, true),
        do: Channels.enable_calendar(channel),
        else: {:ok, channel}

    for member <- members, do: :ok = Channels.add_member(channel, member)
    channel
  end

  setup do
    viewer = user!("U1")
    other = user!("U2")
    %{viewer: viewer, other: other, team: channel!("C1", [viewer, other])}
  end

  test "a subscriber hears about changes in its channels", %{viewer: viewer, team: team} do
    :ok = Changes.subscribe(viewer)
    :ok = Changes.broadcast([team.id], nil)
    assert_receive :calendar_changed
  end

  test "a subscriber hears about changes to its own events in channels it isn't in",
       %{viewer: viewer, other: other} do
    elsewhere = channel!("C2", [other])
    :ok = Changes.subscribe(viewer)
    :ok = Changes.broadcast([elsewhere.id], viewer.id)
    assert_receive :calendar_changed
  end

  test "a repeated channel ID is published once", %{viewer: viewer, team: team} do
    eng = channel!("C2", [viewer])
    :ok = Changes.subscribe(viewer)
    :ok = Changes.broadcast([team.id, eng.id, team.id], nil)
    # One message per subscribed topic (the hook debounces them); the
    # repeated ID adds no third.
    assert_receive :calendar_changed
    assert_receive :calendar_changed
    refute_receive :calendar_changed, 50
  end

  test "a subscriber doesn't hear about other channels or other people's events",
       %{viewer: viewer, other: other} do
    elsewhere = channel!("C2", [other])
    :ok = Changes.subscribe(viewer)
    :ok = Changes.broadcast([elsewhere.id], other.id)
    refute_receive :calendar_changed, 50
  end

  test "a subscriber isn't subscribed to channels with the calendar off",
       %{viewer: viewer} do
    off = channel!("C3", [viewer], enabled: false)
    :ok = Changes.subscribe(viewer)
    :ok = Changes.broadcast([off.id], nil)
    refute_receive :calendar_changed, 50
  end
end
