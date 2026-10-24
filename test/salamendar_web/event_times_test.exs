defmodule SalamendarWeb.EventTimesTest do
  use ExUnit.Case, async: true

  alias Salamendar.Calendar.Event
  alias SalamendarWeb.EventTimes

  defp timed(starts_at, ends_at),
    do: %Event{all_day: false, starts_at: starts_at, ends_at: ends_at}

  defp all_day(first, stop), do: %Event{all_day: true, start_date: first, end_date: stop}

  describe "timed events" do
    test "show in the viewer's zone" do
      event = timed(~U[2026-10-14 14:00:00Z], ~U[2026-10-14 14:15:00Z])

      assert EventTimes.format(event, "America/Chicago") == "Wed, Oct 14, 2026, 9:00 AM – 9:15 AM"
      assert EventTimes.format(event, "Etc/UTC") == "Wed, Oct 14, 2026, 2:00 PM – 2:15 PM"
    end

    test "name both days when they cross midnight in the viewer's zone" do
      event = timed(~U[2026-10-15 02:00:00Z], ~U[2026-10-15 06:00:00Z])

      assert EventTimes.format(event, "America/Chicago") ==
               "Wed, Oct 14, 9:00 PM – Thu, Oct 15, 2026, 1:00 AM"
    end

    test "name both years when they cross one" do
      event = timed(~U[2026-12-31 23:00:00Z], ~U[2027-01-01 01:00:00Z])

      assert EventTimes.format(event, "Etc/UTC") ==
               "Thu, Dec 31, 2026, 11:00 PM – Fri, Jan 1, 2027, 1:00 AM"
    end
  end

  describe "all-day events" do
    test "show one day, or an inclusive range of days, in every zone" do
      assert EventTimes.format(all_day(~D[2026-10-12], ~D[2026-10-13]), "Pacific/Auckland") ==
               "Mon, Oct 12, 2026"

      assert EventTimes.format(all_day(~D[2026-10-12], ~D[2026-10-15]), "Pacific/Honolulu") ==
               "Mon, Oct 12 – Wed, Oct 14, 2026"

      assert EventTimes.format(all_day(~D[2026-12-31], ~D[2027-01-02]), "Etc/UTC") ==
               "Thu, Dec 31, 2026 – Fri, Jan 1, 2027"
    end
  end
end
