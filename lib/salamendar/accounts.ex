defmodule Salamendar.Accounts do
  @moduledoc """
  Users, keyed by their Slack workspace and user IDs.
  """

  alias Salamendar.Accounts.User
  alias Salamendar.Repo

  @doc """
  Returns the user for `team_id`/`user_id`, creating it if needed.

  Any of `:name`, `:time_zone` and `:profile_synced_at` in `attrs` overwrite
  the stored values, so this is safe to call on every Slack event. It is a
  single upsert, so concurrent calls for the same user don't race.
  """
  @spec get_or_create_user(String.t(), String.t(), map()) ::
          {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def get_or_create_user(team_id, user_id, attrs \\ %{}) do
    changeset =
      User.changeset(
        %User{},
        Map.merge(attrs, %{slack_team_id: team_id, slack_user_id: user_id})
      )

    replace =
      Enum.filter([:name, :time_zone, :profile_synced_at], &Map.has_key?(changeset.changes, &1))

    Repo.insert(changeset,
      on_conflict: {:replace, replace ++ [:updated_at]},
      conflict_target: [:slack_team_id, :slack_user_id],
      returning: true
    )
  end
end
