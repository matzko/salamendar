defmodule Salamendar.Render.Period do
  @moduledoc """
  Days in a time zone: today, when a day starts, and which local days an
  event falls on.

  Every other module asks this one, so day logic lives in one place.
  """

  alias Salamendar.Calendar.Event

  @doc """
  The date it is in `time_zone` at `now`.
  """
  @spec today(String.t(), DateTime.t()) :: Date.t()
  def today(time_zone, now \\ DateTime.utc_now()) do
    now |> DateTime.shift_zone!(time_zone) |> DateTime.to_date()
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
