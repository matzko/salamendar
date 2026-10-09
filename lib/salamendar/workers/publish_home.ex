defmodule Salamendar.Workers.PublishHome do
  @moduledoc """
  Republishes a user's Home tab, e.g. after they save an event. It's a job
  because the event form's handler must answer Slack within 3 seconds and
  so can't call Slack itself.
  """

  use Oban.Worker,
    max_attempts: 3,
    unique: [keys: [:team_id, :slack_user_id], states: :scheduled, period: :infinity]

  alias Salamendar.Handlers.Home

  @doc """
  Schedules a republish of `slack_user_id`'s Home tab.
  """
  @spec enqueue(String.t(), String.t()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(team_id, slack_user_id) do
    %{team_id: team_id, slack_user_id: slack_user_id}
    |> new(schedule_in: 1)
    |> Oban.insert()
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"team_id" => team_id, "slack_user_id" => slack_user_id}}) do
    case Home.publish(team_id, slack_user_id) do
      {:ok, _} -> :ok
      {:error, :ratelimited, seconds} -> {:snooze, seconds}
      {:error, reason} -> {:error, reason}
    end
  end
end
