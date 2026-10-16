defmodule SalamendarWeb.HealthControllerTest do
  use SalamendarWeb.ConnCase, async: true

  test "GET /healthz answers 200 without a session", %{conn: conn} do
    conn = get(conn, ~p"/healthz")

    assert response(conn, 200) == "ok"
    assert get_resp_header(conn, "set-cookie") == []
  end
end
