defmodule Salamendar.SlackAPI.UnexpectedResponse do
  @moduledoc """
  A Slack response that is neither `"ok": true` nor a Slack error, e.g. a
  502 from a proxy with an HTML body.
  """

  defexception [:status]

  @impl true
  def message(%{status: status}), do: "unexpected response from Slack (HTTP #{status})"
end
