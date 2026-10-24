defmodule Salamendar.Render.PeriodTest do
  use ExUnit.Case, async: true

  alias Salamendar.Calendar.Event
  alias Salamendar.Render.Period

  describe "today/2" do
    test "a day starts at local midnight, not UTC midnight" do
      # 00:30 on Nov 1 in Tokyo is still Oct 31 in UTC.
      now = ~U[2026-10-31 15:30:00Z]
      assert Period.today("Etc/UTC", now) == ~D[2026-10-31]
      assert Period.today("Asia/Tokyo", now) == ~D[2026-11-01]

      # 23:30 on Oct 31 in Chicago is already Nov 1 in UTC.
      assert Period.today("America/Chicago", ~U[2026-11-01 04:30:00Z]) == ~D[2026-10-31]
    end

    test "zones with :30 and :45 offsets" do
      # Kolkata is +05:30, Kathmandu +05:45 and Chatham +12:45 (+13:45 in
      # its summer).
      assert Period.today("Asia/Kolkata", ~U[2026-10-31 18:29:00Z]) == ~D[2026-10-31]
      assert Period.today("Asia/Kolkata", ~U[2026-10-31 18:30:00Z]) == ~D[2026-11-01]

      assert Period.today("Asia/Kathmandu", ~U[2026-10-31 18:14:00Z]) == ~D[2026-10-31]
      assert Period.today("Asia/Kathmandu", ~U[2026-10-31 18:15:00Z]) == ~D[2026-11-01]

      assert Period.today("Pacific/Chatham", ~U[2026-10-31 10:14:00Z]) == ~D[2026-10-31]
      assert Period.today("Pacific/Chatham", ~U[2026-10-31 10:15:00Z]) == ~D[2026-11-01]
    end

    test "across a daylight saving change" do
      # Chicago falls back at 02:00 on Nov 1, 2026 (07:00 UTC); midnight
      # that night is 06:00 UTC on Nov 2.
      assert Period.today("America/Chicago", ~U[2026-11-02 05:59:00Z]) == ~D[2026-11-01]
      assert Period.today("America/Chicago", ~U[2026-11-02 06:00:00Z]) == ~D[2026-11-02]
    end
  end

  describe "start_of_day/2" do
    test "converts local midnight to UTC" do
      assert Period.start_of_day(~D[2026-10-10], "America/Chicago") == ~U[2026-10-10 05:00:00Z]
      assert Period.start_of_day(~D[2026-10-10], "Asia/Kathmandu") == ~U[2026-10-09 18:15:00Z]
    end

    test "handles a skipped or repeated midnight" do
      # Havana skips from 00:00 to 01:00 on Mar 8, 2026, and repeats
      # midnight on Nov 1, 2026.
      assert Period.start_of_day(~D[2026-03-08], "America/Havana") == ~U[2026-03-08 05:00:00Z]
      assert Period.start_of_day(~D[2026-11-01], "America/Havana") == ~U[2026-11-01 04:00:00Z]
    end
  end

  describe "local_days/2" do
    test "an all-day event covers its dates in any zone" do
      event = %Event{all_day: true, start_date: ~D[2026-10-10], end_date: ~D[2026-10-12]}

      for zone <- ["Pacific/Honolulu", "Pacific/Tongatapu"] do
        assert Period.local_days(event, zone) == Date.range(~D[2026-10-10], ~D[2026-10-11])
      end
    end

    test "a timed event covers the local days it touches" do
      event = %Event{starts_at: ~U[2026-10-10 23:30:00Z], ends_at: ~U[2026-10-11 00:30:00Z]}

      assert Period.local_days(event, "America/Chicago") ==
               Date.range(~D[2026-10-10], ~D[2026-10-10])

      assert Period.local_days(event, "Etc/UTC") == Date.range(~D[2026-10-10], ~D[2026-10-11])
    end

    test "ending at midnight doesn't cover the next day" do
      event = %Event{starts_at: ~U[2026-10-10 22:00:00Z], ends_at: ~U[2026-10-11 00:00:00Z]}
      assert Period.local_days(event, "Etc/UTC") == Date.range(~D[2026-10-10], ~D[2026-10-10])
    end
  end
end
