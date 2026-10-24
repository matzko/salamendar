defmodule SalamendarWeb.EventTimes do
  @moduledoc """
  An event's date and time as one line of text, for the event panel.

  Timed events are shown in the viewer's zone (the browser's, so they match
  the calendar). All-day events show their dates as stored, with the
  exclusive `end_date` turned back into an inclusive last day.
  """

  alias Salamendar.Calendar.Event

  @doc """
  For example `"Wed, Oct 14, 2026, 9:00 AM – 9:15 AM"` or
  `"Mon, Oct 12 – Wed, Oct 14, 2026"`.
  """
  @spec format(Event.t(), String.t()) :: String.t()
  def format(%Event{all_day: true, start_date: first, end_date: end_date}, _time_zone) do
    last = Date.add(end_date, -1)

    cond do
      first == last -> day(first, true)
      first.year == last.year -> "#{day(first, false)} – #{day(last, true)}"
      true -> "#{day(first, true)} – #{day(last, true)}"
    end
  end

  def format(%Event{starts_at: starts_at, ends_at: ends_at}, time_zone) do
    starts_at = DateTime.shift_zone!(starts_at, time_zone)
    ends_at = DateTime.shift_zone!(ends_at, time_zone)

    if DateTime.to_date(starts_at) == DateTime.to_date(ends_at) do
      "#{day(starts_at, true)}, #{time(starts_at)} – #{time(ends_at)}"
    else
      "#{day(starts_at, starts_at.year != ends_at.year)}, #{time(starts_at)} – " <>
        "#{day(ends_at, true)}, #{time(ends_at)}"
    end
  end

  defp day(date, true), do: Calendar.strftime(date, "%a, %b %-d, %Y")
  defp day(date, false), do: Calendar.strftime(date, "%a, %b %-d")

  defp time(datetime), do: Calendar.strftime(datetime, "%-I:%M %p")
end
