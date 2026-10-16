defmodule SalamendarWeb.AuthController do
  use SalamendarWeb, :controller

  alias Salamendar.Accounts
  alias SalamendarWeb.{SignInLink, UserAuth}

  @doc """
  `GET /auth/slack?token=…[&return_to=…]`: swaps a sign-in link from Slack
  for a session, then redirects so the token leaves the address bar and the
  browser history.
  """
  def slack(conn, %{"token" => token} = params) do
    with {:ok, user_id} <- SignInLink.verify(token),
         %Accounts.User{} = user <- Accounts.get_user(user_id) do
      conn
      |> UserAuth.sign_in(user)
      |> redirect(to: local_path(params["return_to"]))
    else
      _ -> redirect(conn, to: ~p"/auth/expired")
    end
  end

  def slack(conn, _params), do: redirect(conn, to: ~p"/auth/expired")

  @doc """
  `GET /auth/expired`: where visitors without a valid session land. Clears
  whatever session there was (e.g. one whose user was deleted).
  """
  def expired(conn, _params) do
    conn
    |> configure_session(drop: true)
    |> put_status(:unauthorized)
    |> render(:message,
      page_title: "Link expired",
      heading: "This link has expired.",
      body: "Open the calendar again from Salamendar's Home tab in Slack."
    )
  end

  @doc """
  `GET /auth/signed-out`: shown after signing out.
  """
  def signed_out(conn, _params) do
    render(conn, :message,
      page_title: "Signed out",
      heading: "You're signed out.",
      body: "Open the calendar again from Salamendar's Home tab in Slack."
    )
  end

  @doc """
  `DELETE /session`: signs out.
  """
  def delete(conn, _params) do
    conn
    |> UserAuth.sign_out()
    |> redirect(to: ~p"/auth/signed-out")
  end

  # Only paths on this site, so the link can't send people elsewhere.
  # `//host` and `/\host` are other hosts to browsers.
  defp local_path("/" <> rest = path) do
    if String.starts_with?(rest, ["/", "\\"]), do: "/", else: path
  end

  defp local_path(_return_to), do: "/"
end
