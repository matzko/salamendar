defmodule SalamendarWeb.Router do
  use SalamendarWeb, :router

  import SalamendarWeb.UserAuth, only: [fetch_current_user: 2]

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {SalamendarWeb.Layouts, :root}
    plug :protect_from_forgery
    # Sign-in links carry a token in the URL, so no page may leak its URL
    # through `Referer`.
    plug :put_secure_browser_headers, %{"referrer-policy" => "no-referrer"}
    plug :fetch_current_user
  end

  # No pipeline: probes get no session and no database work, and aren't
  # logged.
  scope "/", SalamendarWeb do
    get "/healthz", HealthController, :show, log: false
  end

  scope "/", SalamendarWeb do
    pipe_through :browser

    get "/auth/slack", AuthController, :slack
    get "/auth/expired", AuthController, :expired
    get "/auth/signed-out", AuthController, :signed_out
    delete "/session", AuthController, :delete

    live_session :signed_in, on_mount: [{SalamendarWeb.UserAuth, :require_user}] do
      live "/", CalendarLive
      live "/settings", SettingsLive
    end
  end
end
