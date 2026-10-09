defmodule Salamendar.SlackAPI do
  @moduledoc """
  The Slack Web API, as the bot, workers and handlers use it.

  This module is a behaviour plus functions that call the configured
  implementation (`config :salamendar, :slack_api`): `Salamendar.SlackAPI.Client`
  normally, and a Mox mock in tests.

  Results are normalized so callers can react to Slack's errors:

    * `{:ok, body}` when Slack answers `"ok": true`;
    * `{:error, :ratelimited, retry_after_seconds}` when Slack rate limits
      the call (workers return `{:snooze, retry_after_seconds}` to Oban);
    * `{:error, code}` with Slack's `"error"` string, e.g.
      `"canvas_not_found"`;
    * `{:error, exception}` when the request itself failed (e.g. a network
      error).
  """

  @type params :: map()
  @type result ::
          {:ok, map()}
          | {:error, :ratelimited, pos_integer()}
          | {:error, String.t() | Exception.t()}

  @doc """
  Calls a read method such as `conversations.info` with query parameters.
  """
  @callback get(method :: String.t(), params()) :: result()

  @doc """
  Calls a write method such as `canvases.edit` with a JSON body, so nested
  values (`blocks`, `changes`, `document_content`) need no pre-encoding.
  """
  @callback post(method :: String.t(), params()) :: result()

  @doc """
  Streams every item under `resource` (e.g. `"members"`) across all pages of
  a paginated read method. Raises if a page fails.
  """
  @callback stream(method :: String.t(), params(), resource :: String.t()) :: Enumerable.t()

  @doc """
  Replies to a slash command or interaction through its `response_url`.
  Unlike `chat.postEphemeral`, this works in channels the bot isn't in.
  `message` is e.g. `%{text: "…", response_type: "ephemeral"}`.
  """
  @callback respond(response_url :: String.t(), message :: map()) :: :ok | {:error, term()}

  @spec get(String.t(), params()) :: result()
  def get(method, params \\ %{}), do: impl().get(method, params)

  @spec post(String.t(), params()) :: result()
  def post(method, params \\ %{}), do: impl().post(method, params)

  @spec stream(String.t(), params(), String.t()) :: Enumerable.t()
  def stream(method, params, resource), do: impl().stream(method, params, resource)

  @spec respond(String.t(), map()) :: :ok | {:error, term()}
  def respond(response_url, message), do: impl().respond(response_url, message)

  defp impl, do: Application.get_env(:salamendar, :slack_api, Salamendar.SlackAPI.Client)
end
