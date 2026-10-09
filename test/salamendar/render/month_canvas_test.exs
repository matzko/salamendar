defmodule Salamendar.Render.MonthCanvasTest do
  use ExUnit.Case, async: true

  alias Salamendar.Calendar.Event
  alias Salamendar.Render.{MonthCanvas, Period}

  @october Period.month(~D[2026-10-01])
  @opts [time_zone: "America/Chicago", now: ~U[2026-10-09 12:00:00Z]]

  # Chicago is UTC-5 in October.
  defp timed(title, starts_at, ends_at),
    do: %Event{title: title, starts_at: starts_at, ends_at: ends_at}

  defp all_day(title, start_date, end_date),
    do: %Event{title: title, all_day: true, start_date: start_date, end_date: end_date}

  defp grid_rows(markdown) do
    markdown |> String.split("\n") |> Enum.filter(&String.starts_with?(&1, "| "))
  end

  test "renders a month (snapshot)" do
    events = [
      timed("Standup", ~U[2026-10-09 14:00:00Z], ~U[2026-10-09 14:15:00Z]),
      timed("Retro", ~U[2026-10-09 20:00:00Z], ~U[2026-10-09 21:00:00Z]),
      all_day("Holiday", ~D[2026-10-12], ~D[2026-10-13]),
      all_day("Offsite", ~D[2026-10-20], ~D[2026-10-23]),
      # Before "now": left out of "Coming up", still in the grid.
      timed("Kickoff", ~U[2026-10-01 15:00:00Z], ~U[2026-10-01 16:00:00Z]),
      # Late evening locally, after midnight in UTC: shown on Oct 30.
      timed("Late show", ~U[2026-10-31 03:00:00Z], ~U[2026-10-31 05:00:00Z]),
      # A 3-day timed trip running into November.
      timed("Trip", ~U[2026-10-30 14:00:00Z], ~U[2026-11-02 22:00:00Z])
    ]

    assert MonthCanvas.render(events, @october, @opts) == """
           # October 2026
           _Times are in America/Chicago. Salamendar updates this canvas automatically, so changes made here will be lost._

           ## Coming up
           - Fri, Oct 9 9:00 · Standup
           - Fri, Oct 9 15:00 · Retro
           - Mon, Oct 12 · Holiday
           - Oct 20 – Oct 22 · Offsite
           - Oct 30 9:00 – Nov 2 16:00 · Trip

           ## Multi-day events
           - Oct 20 – Oct 22 · Offsite
           - Oct 30 9:00 – Nov 2 16:00 · Trip

           | Sun | Mon | Tue | Wed | Thu | Fri | Sat |
           |---|---|---|---|---|---|---|
           |   |   |   |   | **1**<br>10:00 Kickoff | **2** | **3** |
           | **4** | **5** | **6** | **7** | **8** | **9**<br>9:00 Standup<br>15:00 Retro | **10** |
           | **11** | **12**<br>Holiday | **13** | **14** | **15** | **16** | **17** |
           | **18** | **19** | **20** | **21** | **22** | **23** | **24** |
           | **25** | **26** | **27** | **28** | **29** | **30**<br>22:00 Late show | **31** |
           """
  end

  test "starts the grid on week_start" do
    [header, first | _] =
      grid_rows(MonthCanvas.render([], @october, Keyword.put(@opts, :week_start, 1)))

    assert header == "| Mon | Tue | Wed | Thu | Fri | Sat | Sun |"
    assert first == "|   |   |   | **1** | **2** | **3** | **4** |"
  end

  test "puts the 1st in the right column for a month starting on each weekday" do
    for first <- [
          ~D[2026-02-01],
          ~D[2026-06-01],
          ~D[2026-09-01],
          ~D[2026-04-01],
          ~D[2026-10-01],
          ~D[2026-05-01],
          ~D[2026-08-01]
        ] do
      [_header, first_row | _] = grid_rows(MonthCanvas.render([], Period.month(first), @opts))
      cells = first_row |> String.trim("|") |> String.split("|") |> Enum.map(&String.trim/1)

      assert Enum.find_index(cells, &(&1 == "**1**")) == Period.weekday(first)
      assert length(cells) == 7
    end
  end

  test "a busy day shows three entries and a count" do
    events =
      for hour <- 14..20,
          do:
            timed(
              "Meeting #{hour}",
              DateTime.new!(~D[2026-10-09], Time.new!(hour, 0, 0)),
              DateTime.new!(~D[2026-10-09], Time.new!(hour, 30, 0))
            )

    markdown = MonthCanvas.render(events, @october, @opts)

    assert markdown =~
             "| **9**<br>9:00 Meeting 14<br>10:00 Meeting 15<br>11:00 Meeting 16<br>+4 more |"

    # "Coming up" stops at five.
    assert markdown |> String.split("\n") |> Enum.count(&String.starts_with?(&1, "- ")) == 5
  end

  test "lists all-day events before timed ones in a cell" do
    events = [
      timed("Early", ~U[2026-10-09 05:00:00Z], ~U[2026-10-09 06:00:00Z]),
      all_day("Day off", ~D[2026-10-09], ~D[2026-10-10])
    ]

    assert MonthCanvas.render(events, @october, @opts) =~ "| **9**<br>Day off<br>0:00 Early |"
  end

  test "an empty month" do
    markdown = MonthCanvas.render([], @october, @opts)

    assert markdown =~ "## Coming up\n_Nothing coming up._"
    refute markdown =~ "Multi-day"
    assert length(grid_rows(markdown)) == 6
  end

  test "lists multi-day events that overlap the month, not in cells" do
    events = [
      all_day("Started in September", ~D[2026-09-28], ~D[2026-10-03]),
      all_day("All November", ~D[2026-11-01], ~D[2026-12-01])
    ]

    markdown = MonthCanvas.render(events, @october, @opts)

    assert markdown =~ "## Multi-day events\n- Sep 28 – Oct 2 · Started in September\n\n"
    refute markdown =~ "<br>"
    # "Coming up" can reach into the next month.
    assert markdown =~ "- Nov 1 – Nov 30 · All November"
  end

  test "makes titles safe for tables and free of mentions" do
    events = [
      timed(
        "a | b <br> ![](@U123) [x](https://e.x)\nnext",
        ~U[2026-10-09 14:00:00Z],
        ~U[2026-10-09 15:00:00Z]
      )
    ]

    markdown = MonthCanvas.render(events, @october, @opts)

    assert markdown =~ "9:00 a ∣ b ‹br› ![] (@U123) [x] (https://e.x) next |"
    refute markdown =~ "]("
  end
end
