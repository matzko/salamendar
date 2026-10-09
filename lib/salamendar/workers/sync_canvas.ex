defmodule Salamendar.Workers.SyncCanvas do
  @moduledoc """
  Rewrites a channel's canvas with its current month.

  Enqueue with `enqueue/2` after anything that changes what the canvas
  shows. Jobs wait a few seconds and are unique while scheduled, so a burst
  of changes produces one rewrite. A job that's already running doesn't
  block a new one, since it may have read the data before the latest change.

  The worker never creates canvases (`/salamendar enable` does, so the user
  sees any error), and skips the edit when nothing changed. If Slack says
  the canvas is gone, the ID is cleared rather than the canvas recreated:
  someone deleted it on purpose, and `/salamendar enable` brings it back.
  """

  use Oban.Worker,
    queue: :canvases,
    max_attempts: 10,
    unique: [keys: [:channel_id, :kind], states: :scheduled, period: :infinity]

  require Logger

  alias Salamendar.{Calendar, Channels, Repo, SlackAPI}
  alias Salamendar.Channels.{Canvas, Channel}
  alias Salamendar.Render.{MonthCanvas, Period}

  @debounce_seconds 3
  # "Coming up" can reach this far into the next month.
  @lookahead_days 14

  @doc """
  Schedules a rewrite of `channel_id`'s canvas of `kind`.
  """
  @spec enqueue(Ecto.UUID.t(), Canvas.kind()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(channel_id, kind \\ :month) do
    %{channel_id: channel_id, kind: kind}
    |> new(schedule_in: @debounce_seconds)
    |> Oban.insert()
  end

  @doc """
  Cancels `channel_id`'s pending rewrites, e.g. when its calendar is
  disabled.
  """
  @spec cancel_pending(Ecto.UUID.t()) :: {:ok, non_neg_integer()}
  def cancel_pending(channel_id) do
    [
      worker: __MODULE__,
      state: ~w(scheduled available retryable),
      args: %{channel_id: channel_id}
    ]
    |> Oban.Job.query()
    |> Oban.cancel_all_jobs()
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"channel_id" => channel_id, "kind" => "month"}}) do
    with %Channel{calendar_enabled: true, archived_at: nil} = channel <-
           Repo.get(Channel, channel_id),
         %Canvas{slack_canvas_id: slack_canvas_id} = canvas when is_binary(slack_canvas_id) <-
           Repo.get_by(Canvas, channel_id: channel_id, kind: :month) do
      sync(channel, canvas)
    else
      # Disabled, archived, deleted, or no canvas in Slack: nothing to do.
      _ -> :ok
    end
  end

  def perform(%Oban.Job{args: %{"kind" => kind}}), do: {:cancel, "no renderer for #{kind}"}

  defp sync(channel, canvas) do
    time_zone = Channels.time_zone(channel)
    month = Period.current_month(time_zone)
    range = Date.range(month.first, Date.add(month.last, @lookahead_days))

    markdown =
      channel
      |> Calendar.list_channel_events(range)
      |> MonthCanvas.render(month, time_zone: time_zone, week_start: channel.week_start)

    period = Period.key(month)
    hash = :sha256 |> :crypto.hash(markdown) |> Base.encode16(case: :lower)

    if canvas.rendered_period == period and canvas.content_hash == hash do
      :ok
    else
      edit(canvas, markdown, period, hash)
    end
  end

  defp edit(canvas, markdown, period, hash) do
    changes = [
      %{operation: "replace", document_content: %{type: "markdown", markdown: markdown}}
    ]

    case SlackAPI.post("canvases.edit", %{canvas_id: canvas.slack_canvas_id, changes: changes}) do
      {:ok, _} ->
        {:ok, _} = Channels.mark_canvas_rendered(canvas, period, hash)
        :ok

      {:error, :ratelimited, seconds} ->
        {:snooze, seconds}

      {:error, "canvas_not_found"} ->
        Logger.info("Canvas #{canvas.slack_canvas_id} is gone; not recreating it")
        {:ok, _} = Channels.set_canvas_slack_id(canvas, nil)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end
end
