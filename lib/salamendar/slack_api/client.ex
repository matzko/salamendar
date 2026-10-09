defmodule Salamendar.SlackAPI.Client do
  @moduledoc """
  The real `Salamendar.SlackAPI`, over HTTP with the bot token from config.

  Req's automatic retries are off: a 429 would otherwise sleep inside the
  caller (and Req only retries GETs anyway). Callers get
  `{:error, :ratelimited, seconds}` and decide, e.g. a worker snoozes.

  Extra Req options come from
  `config :salamendar, Salamendar.SlackAPI.Client, req_options: [...]`;
  tests use it to send requests to `Req.Test` stubs.
  """

  @behaviour Salamendar.SlackAPI

  @base_url "https://slack.com/api"
  # Slack doesn't always send `retry-after`; wait a little rather than none.
  @default_retry_after 30

  @impl Salamendar.SlackAPI
  def get(method, params) do
    client() |> Req.get(url: method, params: params) |> normalize()
  end

  @impl Salamendar.SlackAPI
  def post(method, params) do
    client()
    # Without the charset, Slack answers with a `missing_charset` warning.
    |> Req.post(
      url: method,
      body: Jason.encode_to_iodata!(params),
      headers: [{"content-type", "application/json; charset=utf-8"}]
    )
    |> normalize()
  end

  # Response URLs carry their own authorization and answer with plain "ok"
  # rather than Slack's JSON envelope.
  @impl Salamendar.SlackAPI
  def respond(response_url, message) do
    req_options =
      Application.get_env(:salamendar, __MODULE__, []) |> Keyword.get(:req_options, [])

    case Req.post(Req.new(retry: false) |> Req.merge(req_options),
           url: response_url,
           json: message
         ) do
      {:ok, %Req.Response{status: 200}} ->
        :ok

      {:ok, %Req.Response{status: status}} ->
        {:error, %Salamendar.SlackAPI.UnexpectedResponse{status: status}}

      {:error, exception} ->
        {:error, exception}
    end
  end

  # Paging is `Slack.API.stream/4` from the `slack_elixir` fork, which raises
  # if a page fails.
  @impl Salamendar.SlackAPI
  def stream(method, params, resource), do: Slack.API.stream(method, token(), resource, params)

  defp client do
    req_options =
      Application.get_env(:salamendar, __MODULE__, []) |> Keyword.get(:req_options, [])

    Req.new(base_url: @base_url, auth: {:bearer, token()}, retry: false)
    |> Req.merge(req_options)
  end

  defp token, do: Application.get_env(:salamendar, :slack_bot_token)

  @doc false
  @spec normalize({:ok, Req.Response.t()} | {:error, Exception.t()}) ::
          Salamendar.SlackAPI.result()
  def normalize({:ok, %Req.Response{status: 429} = response}),
    do: {:error, :ratelimited, retry_after(response)}

  def normalize({:ok, %Req.Response{body: %{"ok" => true} = body}}), do: {:ok, body}

  def normalize(
        {:ok, %Req.Response{body: %{"ok" => false, "error" => "ratelimited"}} = response}
      ),
      do: {:error, :ratelimited, retry_after(response)}

  def normalize({:ok, %Req.Response{body: %{"ok" => false, "error" => code}}}), do: {:error, code}

  def normalize({:ok, %Req.Response{status: status}}),
    do: {:error, %Salamendar.SlackAPI.UnexpectedResponse{status: status}}

  def normalize({:error, exception}), do: {:error, exception}

  defp retry_after(response) do
    with [value | _] <- Req.Response.get_header(response, "retry-after"),
         {seconds, ""} when seconds > 0 <- Integer.parse(value) do
      seconds
    else
      _ -> @default_retry_after
    end
  end
end
