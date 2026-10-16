defmodule SalamendarWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :salamendar

  # The session lives in a cookie that is signed and encrypted, so it can be
  # neither read nor tampered with.
  @session_options [
    store: :cookie,
    key: "_salamendar_key",
    signing_salt: "OlzP4QVa",
    encryption_salt: "Xq3vJ8tK",
    same_site: "Lax",
    max_age: 30 * 24 * 60 * 60
  ]

  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]],
    longpoll: [connect_info: [session: @session_options]]

  # Serves the files in `priv/static`. Gzip is used once code reloading is
  # off (in prod), for the compressed files that `phx.digest` makes.
  plug Plug.Static,
    at: "/",
    from: :salamendar,
    gzip: not code_reloading?,
    only: SalamendarWeb.static_paths(),
    raise_on_missing_only: code_reloading?

  if code_reloading? do
    socket "/phoenix/live_reload/socket", Phoenix.LiveReloader.Socket
    plug Phoenix.LiveReloader
    plug Phoenix.CodeReloader
  end

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint], log: {__MODULE__, :log_level, []}

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options
  plug SalamendarWeb.Router

  # Health probes would flood the log, so they aren't logged.
  @doc false
  def log_level(%Plug.Conn{path_info: ["healthz"]}), do: false
  def log_level(_conn), do: :info
end
