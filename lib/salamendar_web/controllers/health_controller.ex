defmodule SalamendarWeb.HealthController do
  use SalamendarWeb, :controller

  @doc """
  Answers 200 as long as the endpoint is up, for liveness probes.
  """
  def show(conn, _params) do
    send_resp(conn, 200, "ok")
  end
end
