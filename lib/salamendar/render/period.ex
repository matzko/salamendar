defmodule Salamendar.Render.Period do
  @moduledoc """
  Calendar periods in a time zone: today, the current month, the month
  grid's weeks, period keys, and which local days an event falls on.

  Every other module asks this one, so period logic lives in one place.
  Weekdays are numbered 0 = Sunday … 6 = Saturday, like
  `slack_channels.week_start`.
  """

  alias Salamendar.Calendar.Event

  @type weekday :: 0..6

  @doc """
  The date it is in `time_zone` at `now`.
  """
  @spec today(String.t(), DateTime.t()) :: Date.t()
  def today(time_zone, now \\ DateTime.utc_now()) do
    now |> DateTime.shift_zone!(time_zone) |> DateTime.to_date()
  end

  @doc """
  The whole month containing `date`.
  """
  @spec month(Date.t()) :: Date.Range.t()
  def month(%Date{} = date),
    do: Date.range(Date.beginning_of_month(date), Date.end_of_month(date))

  @doc """
  The month it is in `time_zone` at `now`.
  """
  @spec current_month(String.t(), DateTime.t()) :: Date.Range.t()
  def current_month(time_zone, now \\ DateTime.utc_now()), do: month(today(time_zone, now))

  @doc """
  The key stored in `channel_canvases.rendered_period`: the ISO date of the
  period's first day, e.g. `"2026-10-01"`.
  """
  @spec key(Date.Range.t()) :: String.t()
  def key(%Date.Range{first: first}), do: Date.to_iso8601(first)

  @doc """
  The weekday of `date`, 0 = Sunday … 6 = Saturday.
  """
  @spec weekday(Date.t()) :: weekday()
  def weekday(%Date{} = date), do: rem(Date.day_of_week(date), 7)

  @doc """
  The seven weekdays in grid order, starting at `week_start`.
  """
  @spec weekdays(weekday()) :: [weekday()]
  def weekdays(week_start) when week_start in 0..6, do: Enum.map(0..6, &rem(week_start + &1, 7))

  @doc """
  The rows of a grid for `month`: lists of seven, each a date in the month or
  `nil` for a day in a neighboring month.
  """
  @spec weeks(Date.Range.t(), weekday()) :: [[Date.t() | nil]]
  def weeks(%Date.Range{first: first} = month, week_start) when week_start in 0..6 do
    leading = rem(weekday(first) - week_start + 7, 7)
    days = List.duplicate(nil, leading) ++ Enum.to_list(month)
    trailing = rem(7 - rem(length(days), 7), 7)

    (days ++ List.duplicate(nil, trailing)) |> Enum.chunk_every(7)
  end

  @doc """
  The instant `date` starts in `time_zone`, in UTC.

  Where a daylight saving change skips midnight, the day starts at the first
  time that exists; where midnight happens twice, at the first one.
  """
  @spec start_of_day(Date.t(), String.t()) :: DateTime.t()
  def start_of_day(%Date{} = date, time_zone) do
    case DateTime.new(date, ~T[00:00:00], time_zone) do
      {:ok, datetime} -> DateTime.shift_zone!(datetime, "Etc/UTC")
      {:gap, _before, just_after} -> DateTime.shift_zone!(just_after, "Etc/UTC")
      {:ambiguous, first, _second} -> DateTime.shift_zone!(first, "Etc/UTC")
    end
  end

  @doc """
  The local days in `time_zone` that `event` covers (inclusive).

  All-day events cover the same dates everywhere. A timed event ending
  exactly at midnight doesn't cover the next day.
  """
  @spec local_days(Event.t(), String.t()) :: Date.Range.t()
  def local_days(%Event{all_day: true, start_date: start_date, end_date: end_date}, _time_zone) do
    Date.range(start_date, Date.add(end_date, -1))
  end

  def local_days(%Event{starts_at: starts_at, ends_at: ends_at}, time_zone) do
    last_instant = DateTime.add(ends_at, -1, :microsecond)
    Date.range(today(time_zone, starts_at), today(time_zone, last_instant))
  end
end
