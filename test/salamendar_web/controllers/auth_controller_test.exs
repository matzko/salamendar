defmodule SalamendarWeb.AuthControllerTest do
  use SalamendarWeb.ConnCase, async: true

  alias Salamendar.{Accounts, Repo}
  alias SalamendarWeb.SignInLink

  setup do
    {:ok, user} = Accounts.get_or_create_user("TAU1", "U1", %{name: "Ada"})
    %{user: user}
  end

  # The path and query of a sign-in link, as the browser requests it.
  defp link_path(user, opts \\ []) do
    %URI{path: path, query: query} = URI.parse(SignInLink.url(user, opts))
    path <> "?" <> query
  end

  defp token(user, opts) do
    Phoenix.Token.sign(SalamendarWeb.Endpoint, Keyword.get(opts, :salt, "slack link"), user.id,
      signed_at: Keyword.get(opts, :signed_at, System.system_time(:second))
    )
  end

  describe "GET /auth/slack" do
    test "a valid link signs in and redirects without the token", %{conn: conn, user: user} do
      conn = get(conn, link_path(user))

      assert redirected_to(conn) == "/"
      assert get_session(conn, :user_id) == user.id
      assert get_resp_header(conn, "referrer-policy") == ["no-referrer"]

      # The session works for the page it lands on.
      assert html_response(get(recycle(conn), ~p"/"), 200) =~ "Signed in as Ada"
    end

    test "redirects to a local return_to", %{conn: conn, user: user} do
      conn = get(conn, link_path(user, return_to: "/?channel=C1"))
      assert redirected_to(conn) == "/?channel=C1"
    end

    test "refuses a return_to on another site", %{conn: conn, user: user} do
      for return_to <- ["https://evil.example", "//evil.example", "/\\evil.example", "evil"] do
        conn = get(conn, link_path(user, return_to: return_to))
        assert redirected_to(conn) == "/", "#{return_to} wasn't refused"
      end
    end

    test "an expired link shows the expired page", %{conn: conn, user: user} do
      a_day_ago = System.system_time(:second) - 24 * 60 * 60 - 1
      conn = get(conn, ~p"/auth/slack?#{[token: token(user, signed_at: a_day_ago)]}")

      assert redirected_to(conn) == ~p"/auth/expired"
      refute get_session(conn, :user_id)
    end

    test "a forged link shows the expired page", %{conn: conn, user: user} do
      for token <- [token(user, salt: "something else"), "not-a-token"] do
        conn = get(conn, ~p"/auth/slack?#{[token: token]}")
        assert redirected_to(conn) == ~p"/auth/expired"
        refute get_session(conn, :user_id)
      end
    end

    test "a link without a token shows the expired page", %{conn: conn} do
      assert redirected_to(get(conn, ~p"/auth/slack")) == ~p"/auth/expired"
    end

    test "a link for a deleted user shows the expired page", %{conn: conn, user: user} do
      path = link_path(user)
      Repo.delete!(user)

      assert redirected_to(get(conn, path)) == ~p"/auth/expired"
    end

    test "replaces an existing session", %{conn: conn, user: user} do
      {:ok, other} = Accounts.get_or_create_user("TAU1", "U2")

      conn = conn |> sign_in(other) |> get(link_path(user))
      assert get_session(conn, :user_id) == user.id
    end
  end

  test "GET /auth/expired explains and clears the session", %{conn: conn, user: user} do
    conn = conn |> sign_in(user) |> get(~p"/auth/expired")

    assert html_response(conn, 401) =~ "This link has expired."
    assert conn.private.plug_session_info == :drop
  end

  test "DELETE /session signs out", %{conn: conn, user: user} do
    conn = conn |> sign_in(user) |> delete(~p"/session")

    assert redirected_to(conn) == ~p"/auth/signed-out"
    assert conn.private.plug_session_info == :drop
    assert html_response(get(recycle(conn), ~p"/auth/signed-out"), 200) =~ "signed out"
  end
end
