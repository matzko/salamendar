defmodule Salamendar.Render.MonthCanvas do
  @moduledoc """
  Canvas markdown for a channel's month: a short "Coming up" list (easier
  to read on a phone than the grid), the month's multi-day events, then a
  7-column grid.

  Multi-day events (all-day events over more than one day, and timed events
  of 24 hours or more) are listed above the grid rather than repeated in
  every cell. Other events go in the cell of the day they start, at most
  three per cell.

  Canvas markdown has no working backslash escapes (checked in #test-bot,
  2026-10-09), so user text is made safe by replacing characters instead:
  `|` would end a table cell, `<…>` could become HTML such as `<br>`, and
  `](` could form a link or a `![](@U…)` mention, which would notify people
  on every edit.
  """

  alias Salamendar.Calendar.Event
  alias Salamendar.Render.Period

  @cell_limit 3
  @upcoming_limit 5
  @weekday_names ~w(Sun Mon Tue Wed Thu Fri Sat)

  @doc """
  Markdown for `month` (e.g. `Period.month/1`), showing `events`.

  `events` may include events outside the month (e.g. so "Coming up" can
  reach into the next month); only the month's days get grid cells.

  Options:

    * `:time_zone` (required): the channel's time zone.
    * `:week_start` (default `0`, Sunday): the grid's first column.
    * `:now` (default: the current time): where "Coming up" starts.
  """
  @spec render([Event.t()], Date.Range.t(), keyword()) :: String.t()
  def render(events, %Date.Range{} = month, opts) do
    time_zone = Keyword.fetch!(opts, :time_zone)
    week_start = Keyword.get(opts, :week_start, 0)
    now = Keyword.get(opts, :now, DateTime.utc_now())

    events =
      events
      |> Enum.map(&{&1, Period.local_days(&1, time_zone)})
      |> Enum.sort_by(fn {event, _days} -> sort_key(event, time_zone) end)

    [
      header(month, time_zone),
      upcoming(events, now, time_zone),
      multi_day(events, month, time_zone),
      grid(events, month, week_start, time_zone)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
    |> Kernel.<>("\n")
  end

  defp header(month, time_zone) do
    """
    # #{Calendar.strftime(month.first, "%B %Y")}
    _Times are in #{time_zone}. Salamendar updates this canvas automatically, \
    so changes made here will be lost._\
    """
  end

  defp upcoming(events, now, time_zone) do
    items =
      events
      |> Enum.filter(fn {event, _days} -> ends_after?(event, now, time_zone) end)
      |> Enum.take(@upcoming_limit)
      |> Enum.map(fn {event, days} ->
        "- #{when_text(event, days, time_zone)} · #{safe(event.title)}"
      end)

    body = if items == [], do: "_Nothing coming up._", else: Enum.join(items, "\n")
    "## Coming up\n" <> body
  end

  defp multi_day(events, month, time_zone) do
    items =
      for {event, days} <- events,
          multi_day?(event),
          overlaps?(days, month) do
        "- #{when_text(event, days, time_zone)} · #{safe(event.title)}"
      end

    if items != [], do: "## Multi-day events\n" <> Enum.join(items, "\n")
  end

  defp grid(events, month, week_start, time_zone) do
    by_day =
      events
      |> Enum.reject(fn {event, _days} -> multi_day?(event) end)
      |> Enum.group_by(fn {_event, days} -> days.first end, fn {event, _days} -> event end)

    columns = Period.weekdays(week_start)
    names = Enum.map(columns, &Enum.at(@weekday_names, &1))

    rows =
      for week <- Period.weeks(month, week_start) do
        "| " <> Enum.map_join(week, " | ", &cell(&1, Map.get(by_day, &1, []), time_zone)) <> " |"
      end

    Enum.join(
      ["| " <> Enum.join(names, " | ") <> " |", "|" <> String.duplicate("---|", 7) | rows],
      "\n"
    )
  end

  defp cell(nil, _events, _time_zone), do: " "

  defp cell(date, events, time_zone) do
    {shown, hidden} = Enum.split(events, @cell_limit)
    more = if hidden == [], do: [], else: ["+#{length(hidden)} more"]

    Enum.join(["**#{date.day}**" | Enum.map(shown, &entry(&1, time_zone))] ++ more, "<br>")
  end

  defp entry(%Event{all_day: true} = event, _time_zone), do: safe(event.title)
  defp entry(event, time_zone), do: "#{time(event.starts_at, time_zone)} #{safe(event.title)}"

  # "Fri, Oct 9 9:00", "Sat, Oct 10" (all day), "Oct 8 – Oct 12" or
  # "Oct 30 9:00 – Nov 2 17:00".
  defp when_text(%Event{all_day: true}, days, _time_zone) do
    if days.first == days.last,
      do: Calendar.strftime(days.first, "%a, %b %-d"),
      else: "#{short_date(days.first)} – #{short_date(days.last)}"
  end

  defp when_text(event, days, time_zone) do
    if multi_day?(event) do
      "#{short_date(days.first)} #{time(event.starts_at, time_zone)} – " <>
        "#{short_date(days.last)} #{time(event.ends_at, time_zone)}"
    else
      "#{Calendar.strftime(days.first, "%a, %b %-d")} #{time(event.starts_at, time_zone)}"
    end
  end

  defp multi_day?(%Event{all_day: true, start_date: start_date, end_date: end_date}),
    do: Date.diff(end_date, start_date) > 1

  defp multi_day?(%Event{starts_at: starts_at, ends_at: ends_at}),
    do: DateTime.diff(ends_at, starts_at, :hour) >= 24

  defp overlaps?(days, month),
    do:
      Date.compare(days.first, month.last) != :gt and Date.compare(days.last, month.first) != :lt

  defp ends_after?(%Event{all_day: true, end_date: end_date}, now, time_zone),
    do: Date.compare(end_date, Period.today(time_zone, now)) == :gt

  defp ends_after?(%Event{ends_at: ends_at}, now, _time_zone),
    do: DateTime.compare(ends_at, now) == :gt

  # All-day events sort as starting at local midnight, ahead of timed events
  # that start then.
  defp sort_key(%Event{all_day: true} = event, time_zone),
    do:
      {DateTime.to_unix(Period.start_of_day(event.start_date, time_zone), :microsecond), 0,
       event.title}

  defp sort_key(event, _time_zone),
    do: {DateTime.to_unix(event.starts_at, :microsecond), 1, event.title}

  defp time(datetime, time_zone),
    do: datetime |> DateTime.shift_zone!(time_zone) |> Calendar.strftime("%-H:%M")

  defp short_date(date), do: Calendar.strftime(date, "%b %-d")

  defp safe(text) do
    text
    |> String.replace(~r/\s+/, " ")
    |> String.replace("|", "∣")
    |> String.replace("<", "‹")
    |> String.replace(">", "›")
    |> String.replace("](", "] (")
    |> String.trim()
  end
end
