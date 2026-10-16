defmodule SalamendarWeb.UserAuth do
  @moduledoc """
  Sessions for the web calendar.

  Signing in puts the user's ID in the session (see
  `SalamendarWeb.AuthController`). Plugs and LiveViews then load the user
  from it as `:current_user`. A LiveView visitor without a session, or
  whose user row is gone, is sent to the "link has expired" page, which
  also clears the session.
  """

  use SalamendarWeb, :verified_routes

  import Plug.Conn

  alias Salamendar.Accounts
  alias Salamendar.Accounts.User

  @doc """
  Starts a fresh session for `user`. Renewing the session ID guards against
  session fixation.
  """
  @spec sign_in(Plug.Conn.t(), User.t()) :: Plug.Conn.t()
  def sign_in(conn, %User{id: user_id}) do
    conn
    |> configure_session(renew: true)
    |> clear_session()
    |> put_session(:user_id, user_id)
    |> put_session(:live_socket_id, live_socket_id(user_id))
  end

  @doc """
  Ends the session, and disconnects the user's open LiveViews.
  """
  @spec sign_out(Plug.Conn.t()) :: Plug.Conn.t()
  def sign_out(conn) do
    if live_socket_id = get_session(conn, :live_socket_id) do
      SalamendarWeb.Endpoint.broadcast(live_socket_id, "disconnect", %{})
    end

    configure_session(conn, drop: true)
  end

  @doc """
  Plug that assigns `:current_user` from the session, or nil.
  """
  @spec fetch_current_user(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def fetch_current_user(conn, _opts) do
    assign(conn, :current_user, session_user(get_session(conn)))
  end

  @doc """
  `on_mount` hook for LiveViews: `:require_user` assigns `:current_user`
  or redirects to the expired-link page.
  """
  def on_mount(:require_user, _params, session, socket) do
    case session_user(session) do
      %User{} = user ->
        {:cont, Phoenix.Component.assign(socket, :current_user, user)}

      nil ->
        {:halt, Phoenix.LiveView.redirect(socket, to: ~p"/auth/expired")}
    end
  end

  defp session_user(%{"user_id" => user_id}) when is_binary(user_id),
    do: Accounts.get_user(user_id)

  defp session_user(_session), do: nil

  defp live_socket_id(user_id), do: "users_sessions:#{user_id}"
end
