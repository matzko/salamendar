defmodule SalamendarWeb.EventJSONTest do
  use ExUnit.Case, async: true

  alias Salamendar.Accounts.User
  alias Salamendar.Calendar.Event
  alias Salamendar.Channels.Channel
  alias SalamendarWeb.EventJSON

  @owner %User{id: "owner", name: "Ada", slack_user_id: "U1", color: "red"}
  @viewer %User{id: "viewer", slack_user_id: "U2"}
  @team %Channel{id: "c-team", name: "team", slack_channel_id: "C1"}
  @secret %Channel{id: "c-secret", name: "secret", slack_channel_id: "C2"}

  defp event(attrs) do
    struct!(
      %Event{
        id: "event-1",
        title: "Standup",
        owner_id: @owner.id,
        owner: @owner,
        channels: [@team],
        starts_at: ~U[2026-10-14 15:00:00.123456Z],
        ends_at: ~U[2026-10-14 15:15:00.000000Z]
      },
      attrs
    )
  end

  test "renders a timed event as UTC instants" do
    assert EventJSON.event(event([]), @viewer, MapSet.new([@team.id])) == %{
             id: "event-1",
             title: "Standup",
             start: "2026-10-14T15:00:00Z",
             end: "2026-10-14T15:15:00Z",
             allDay: false,
             backgroundColor: "#d50000",
             textColor: "#ffffff",
             startEditable: false,
             durationEditable: false,
             extendedProps: %{owner: "Ada", channels: ["team"], description: nil}
           }
  end

  test "renders an all-day event with its exclusive end date" do
    json =
      EventJSON.event(
        event(
          all_day: true,
          starts_at: nil,
          ends_at: nil,
          start_date: ~D[2026-10-12],
          end_date: ~D[2026-10-15]
        ),
        @viewer,
        MapSet.new()
      )

    assert %{start: "2026-10-12", end: "2026-10-15", allDay: true} = json
  end

  test "only the owner's own events are draggable, and `editable` is never sent" do
    others = EventJSON.event(event([]), @viewer, MapSet.new())
    own = EventJSON.event(event([]), @owner, MapSet.new())

    assert %{startEditable: false, durationEditable: false} = others
    assert %{startEditable: true, durationEditable: true} = own
    refute Map.has_key?(others, :editable)
    refute Map.has_key?(own, :editable)
  end

  test "names only the channels the viewer can see" do
    json = EventJSON.event(event(channels: [@team, @secret]), @viewer, MapSet.new([@team.id]))
    assert json.extendedProps.channels == ["team"]
  end

  test "an event whose owner is gone gets the default color" do
    json = EventJSON.event(event(owner_id: nil, owner: nil), @viewer, MapSet.new())

    assert %{backgroundColor: "#1a73e8", startEditable: false} = json
    assert json.extendedProps.owner == nil
  end
end
