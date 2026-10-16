defmodule SalamendarWeb.HomeLiveTest do
  use SalamendarWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Salamendar.{Accounts, Repo}

  setup do
    {:ok, user} = Accounts.get_or_create_user("THL1", "U1", %{name: "Ada"})
    %{user: user}
  end

  test "renders for a signed-in user and connects", %{conn: conn, user: user} do
    conn = conn |> sign_in(user) |> get(~p"/")
    assert html_response(conn, 200) =~ "Signed in as Ada"

    {:ok, _view, html} = live(conn)
    assert html =~ "coming soon"
  end

  test "pages send no Referer", %{conn: conn, user: user} do
    conn = conn |> sign_in(user) |> get(~p"/")
    assert get_resp_header(conn, "referrer-policy") == ["no-referrer"]
  end

  test "sends visitors without a session to the expired page", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/auth/expired"}}} = live(conn, ~p"/")
  end

  test "sends a deleted user to the expired page", %{conn: conn, user: user} do
    conn = sign_in(conn, user)
    Repo.delete!(user)

    assert {:error, {:redirect, %{to: "/auth/expired"}}} = live(conn, ~p"/")
  end
end
