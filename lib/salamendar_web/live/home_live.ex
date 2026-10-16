defmodule SalamendarWeb.HomeLive do
  @moduledoc """
  A placeholder at `/` that proves the LiveView socket, layout and assets
  work. `CalendarLive` replaces it.
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
      <p>The calendar is coming soon.</p>
    </Layouts.app>
    """
  end
end
