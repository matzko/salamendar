defmodule SalamendarWeb.EventParamsTest do
  use ExUnit.Case, async: true

  alias Salamendar.Calendar.Event
  alias Salamendar.Channels.Channel
  alias SalamendarWeb.EventParams

  @chicago "America/Chicago"

  describe "new/2" do
    test "starts at the next full hour, for an hour, in the zone" do
      assert %{
               "all_day" => false,
               "starts_at" => "2026-10-14T10:00",
               "ends_at" => "2026-10-14T11:00",
               "start_date" => "2026-10-14",
               "end_date" => "2026-10-14"
             } = EventParams.new(@chicago, ~U[2026-10-14 14:20:00Z])
    end
  end

  describe "from_selection/2" do
    test "an all-day selection gives inclusive dates" do
      params =
        EventParams.from_selection(
          %{
            "all_day" => true,
            "start" => "2026-10-12T05:00:00.000Z",
            "end" => "2026-10-15T05:00:00.000Z",
            "start_date" => "2026-10-12",
            "end_date" => "2026-10-15"
          },
          @chicago
        )

      assert %{
               "all_day" => true,
               "start_date" => "2026-10-12",
               "end_date" => "2026-10-14",
               "starts_at" => "2026-10-12T09:00",
               "ends_at" => "2026-10-14T17:00"
             } = params
    end

    test "a timed selection gives local times" do
      params =
        EventParams.from_selection(
          %{
            "all_day" => false,
            "start" => "2026-10-14T14:00:00.000Z",
            "end" => "2026-10-14T15:30:00.000Z",
            "start_date" => "2026-10-14",
            "end_date" => "2026-10-14"
          },
          @chicago
        )

      assert %{
               "all_day" => false,
               "starts_at" => "2026-10-14T09:00",
               "ends_at" => "2026-10-14T10:30",
               "start_date" => "2026-10-14",
               "end_date" => "2026-10-14"
             } = params
    end

    test "a timed selection ending at midnight doesn't cover the next day" do
      params =
        EventParams.from_selection(
          %{"start" => "2026-10-14T04:00:00Z", "end" => "2026-10-15T05:00:00Z"},
          @chicago
        )

      assert %{"start_date" => "2026-10-13", "end_date" => "2026-10-14"} = params
    end

    test "an unreadable selection falls back to a new event" do
      for bad <- [%{}, %{"start" => "x", "end" => "y"}, %{"all_day" => true, "start_date" => "x"}] do
        assert %{"all_day" => false, "starts_at" => _} = EventParams.from_selection(bad, @chicago)
      end
    end
  end

  describe "from_event/2" do
    test "fills in a timed event in the zone, with dates to switch to" do
      event = %Event{
        title: "Standup",
        description: nil,
        all_day: false,
        starts_at: ~U[2026-10-14 14:00:00Z],
        ends_at: ~U[2026-10-14 14:15:00Z],
        channels: [%Channel{id: "c1"}, %Channel{id: "c2"}]
      }

      assert EventParams.from_event(event, @chicago) == %{
               "title" => "Standup",
               "description" => "",
               "all_day" => false,
               "starts_at" => "2026-10-14T09:00",
               "ends_at" => "2026-10-14T09:15",
               "start_date" => "2026-10-14",
               "end_date" => "2026-10-14",
               "channel_ids" => ["c1", "c2"]
             }
    end

    test "fills in an all-day event with its inclusive last day" do
      event = %Event{
        title: "Offsite",
        description: "Bring snacks",
        all_day: true,
        start_date: ~D[2026-10-12],
        end_date: ~D[2026-10-15],
        channels: []
      }

      assert %{
               "all_day" => true,
               "start_date" => "2026-10-12",
               "end_date" => "2026-10-14",
               "starts_at" => "2026-10-12T09:00",
               "ends_at" => "2026-10-14T17:00",
               "description" => "Bring snacks"
             } = EventParams.from_event(event, @chicago)
    end
  end

  describe "to_attrs/2" do
    test "reads datetime-local values in the zone" do
      {attrs, []} =
        EventParams.to_attrs(
          %{
            "title" => "Standup",
            "all_day" => "false",
            "starts_at" => "2026-10-14T09:00",
            "ends_at" => "2026-10-14T09:15",
            "start_date" => "2026-10-14",
            "end_date" => "2026-10-14",
            "description" => ""
          },
          @chicago
        )

      assert attrs == %{
               title: "Standup",
               description: nil,
               all_day: false,
               starts_at: ~U[2026-10-14 14:00:00Z],
               ends_at: ~U[2026-10-14 14:15:00Z],
               start_date: nil,
               end_date: nil
             }
    end

    test "uses the same wall-clock time on both sides of the DST change" do
      {before, _} =
        EventParams.to_attrs(
          %{"starts_at" => "2026-10-31T09:00", "ends_at" => "2026-10-31T10:00"},
          @chicago
        )

      {later, _} =
        EventParams.to_attrs(
          %{"starts_at" => "2026-11-01T09:00", "ends_at" => "2026-11-01T10:00"},
          @chicago
        )

      assert before.starts_at == ~U[2026-10-31 14:00:00Z]
      assert later.starts_at == ~U[2026-11-01 15:00:00Z]
    end

    test "reads a time skipped by DST as the first time after it" do
      {attrs, _} =
        EventParams.to_attrs(
          %{"starts_at" => "2026-03-08T02:30", "ends_at" => "2026-03-08T04:00"},
          @chicago
        )

      # 3:00 CDT.
      assert attrs.starts_at == ~U[2026-03-08 08:00:00Z]
    end

    test "stores an all-day event's end exclusive" do
      {attrs, _} =
        EventParams.to_attrs(
          %{
            "all_day" => "true",
            "start_date" => "2026-10-12",
            "end_date" => "2026-10-14",
            "starts_at" => "2026-10-12T09:00",
            "ends_at" => "2026-10-14T17:00"
          },
          @chicago
        )

      assert %{
               all_day: true,
               start_date: ~D[2026-10-12],
               end_date: ~D[2026-10-15],
               starts_at: nil,
               ends_at: nil
             } = attrs
    end

    test "turns unreadable values into nil" do
      {timed, _} = EventParams.to_attrs(%{"starts_at" => "soon", "ends_at" => ""}, @chicago)
      assert {timed.starts_at, timed.ends_at} == {nil, nil}

      {all_day, _} = EventParams.to_attrs(%{"all_day" => "true", "start_date" => "x"}, @chicago)
      assert {all_day.start_date, all_day.end_date} == {nil, nil}
    end

    test "keeps only channel IDs that are UUIDs, once each" do
      id = Ecto.UUID.generate()

      assert {_, [^id]} =
               EventParams.to_attrs(%{"channel_ids" => ["", id, "nope", id]}, @chicago)

      assert {_, []} = EventParams.to_attrs(%{"channel_ids" => "nope"}, @chicago)
    end
  end

  test "errors/1 puts changeset errors on the form's fields" do
    changeset =
      %Event{slack_team_id: "T1", time_zone: @chicago}
      |> Event.changeset(%{
        title: "",
        starts_at: ~U[2026-10-14 15:00:00Z],
        ends_at: ~U[2026-10-14 14:00:00Z]
      })
      |> Ecto.Changeset.add_error(:channels, "must include at least one channel")

    errors = EventParams.errors(changeset)

    assert {"can't be blank", _} = errors[:title]
    assert {"must be after the start", _} = errors[:ends_at]
    assert {"must include at least one channel", _} = errors[:channel_ids]
  end
end
