defmodule SalamendarWeb.RequestLogTest do
  # Not async: the test config only logs warnings, so these tests lower the
  # global level to `:debug` (which also shows router parameters) while they
  # run.
  use SalamendarWeb.ConnCase, async: false

  import ExUnit.CaptureLog

  alias Salamendar.Accounts
  alias SalamendarWeb.SignInLink

  setup do
    {:ok, user} = Accounts.get_or_create_user("TRL1", "U1")
    level = Logger.level()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: level) end)
    %{user: user}
  end

  test "requests are logged", %{conn: conn} do
    assert capture_log(fn -> get(conn, ~p"/auth/expired") end) =~ "GET /auth/expired"
  end

  test "GET /healthz isn't logged", %{conn: conn} do
    assert capture_log(fn -> get(conn, ~p"/healthz") end) == ""
  end

  test "sign-in tokens aren't logged", %{conn: conn, user: user} do
    %URI{path: path, query: query} = URI.parse(SignInLink.url(user))
    %{"token" => token} = URI.decode_query(query)

    log = capture_log(fn -> get(conn, path <> "?" <> query) end)

    assert log =~ "GET /auth/slack"
    assert log =~ ~s("token" => "[FILTERED]")
    refute log =~ token
  end
end
