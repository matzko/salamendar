defmodule Salamendar.Workers.DeleteCanvases do
  @moduledoc """
  Deletes a channel's canvases in Slack, and then their rows, after its
  calendar is disabled (by `/salamendar disable` or the bot being removed).

  It runs as a job so a failure is retried rather than leaving a stale
  canvas behind. Deleting a canvas also removes its channel tab, and a
  canvas someone already deleted counts as done.
  """

  use Oban.Worker, queue: :canvases, max_attempts: 10

  alias Salamendar.{Channels, Repo, SlackAPI}
  alias Salamendar.Channels.Channel
  alias Salamendar.Workers.SyncCanvas

  @doc """
  Cancels `channel_id`'s pending canvas rewrites and schedules the deletion.
  """
  @spec enqueue(Ecto.UUID.t()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(channel_id) do
    {:ok, _} = SyncCanvas.cancel_pending(channel_id)
    %{channel_id: channel_id} |> new() |> Oban.insert()
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"channel_id" => channel_id}}) do
    case Repo.get(Channel, channel_id) do
      # Enabled again before this ran: the canvases are still in use.
      %Channel{calendar_enabled: true} -> :ok
      # Deleted: its canvas rows went with it.
      nil -> :ok
      channel -> channel |> Channels.list_canvases() |> delete_all()
    end
  end

  defp delete_all([]), do: :ok

  defp delete_all([canvas | rest]) do
    case delete(canvas) do
      :ok ->
        :ok = Channels.delete_canvas(canvas)
        delete_all(rest)

      # Rows already deleted stay deleted; the retry picks up the rest.
      {:error, :ratelimited, seconds} ->
        {:snooze, seconds}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp delete(%{slack_canvas_id: nil}), do: :ok

  defp delete(%{slack_canvas_id: slack_canvas_id}) do
    case SlackAPI.post("canvases.delete", %{canvas_id: slack_canvas_id}) do
      {:ok, _} -> :ok
      {:error, "canvas_not_found"} -> :ok
      error -> error
    end
  end
end
