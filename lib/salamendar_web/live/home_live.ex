defmodule SalamendarWeb.HomeLive do
  @moduledoc """
  A placeholder at `/` that proves the LiveView socket, layout, assets and
  sign-in work. `CalendarLive` replaces it.
  """
  use SalamendarWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Calendar")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <h1>Salamendar</h1>
      <p>Signed in as {@current_user.name || @current_user.slack_user_id}.</p>
      <p>The calendar is coming soon.</p>
      <.link href={~p"/session"} method="delete">Sign out</.link>
    </Layouts.app>
    """
  end
end
