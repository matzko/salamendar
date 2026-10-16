defmodule SalamendarWeb.HomeLiveTest do
  use SalamendarWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  test "GET / renders the page and connects", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert html_response(conn, 200) =~ "Salamendar"

    {:ok, _view, html} = live(conn)
    assert html =~ "coming soon"
  end

  test "pages send no Referer", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert get_resp_header(conn, "referrer-policy") == ["no-referrer"]
  end
end
