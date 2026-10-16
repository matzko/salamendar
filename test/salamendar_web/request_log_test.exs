defmodule SalamendarWeb.RequestLogTest do
  # Not async: the test config only logs warnings, and request logs are
  # `:info`, so these tests lower the global level while they run.
  use SalamendarWeb.ConnCase, async: false

  import ExUnit.CaptureLog

  setup do
    level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: level) end)
  end

  test "requests are logged", %{conn: conn} do
    assert capture_log(fn -> get(conn, ~p"/") end) =~ "GET /"
  end

  test "GET /healthz isn't logged", %{conn: conn} do
    assert capture_log(fn -> get(conn, ~p"/healthz") end) == ""
  end
end
