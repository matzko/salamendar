defmodule Salamendar.Workers.Rollover do
  @moduledoc """
  Keeps canvases current as time passes. Runs every 15 minutes (Oban cron),
  which also catches month changes in zones with `:30` and `:45` offsets.

  It enqueues `SyncCanvas` for every enabled channel's canvas, not only
  those whose month changed: "Coming up" drops events once they end, so a
  canvas can go stale within a month. `SyncCanvas` skips the Slack call
  when the rendered canvas hasn't changed, so most runs edit nothing.
  """

  use Oban.Worker, max_attempts: 3

  alias Salamendar.Channels
  alias Salamendar.Workers.SyncCanvas

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    for channel <- Channels.list_enabled_channels(),
        canvas <- Channels.list_canvases(channel),
        canvas.slack_canvas_id do
      {:ok, _} = SyncCanvas.enqueue(channel.id, canvas.kind)
    end

    :ok
  end
end
