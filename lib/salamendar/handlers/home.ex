defmodule Salamendar.Handlers.Home do
  @moduledoc """
  Publishes a user's App Home tab: their events for today, in their time
  zone.

  The user's name and time zone are refreshed from `users.info` when they
  were last fetched more than a day ago, so stub users created by member
  backfill get filled in the first time they open the Home tab.
  """

  require Logger

  alias Salamendar.{Accounts, Calendar, Repo, SlackAPI}
  alias Salamendar.Accounts.User
  alias Salamendar.Render.{HomeTab, Period}

  @profile_max_age_seconds 24 * 60 * 60

  @doc """
  Renders and publishes `slack_user_id`'s Home tab.
  """
  @spec publish(String.t(), String.t()) :: SlackAPI.result()
  def publish(team_id, slack_user_id) do
    {:ok, user} = Accounts.get_or_create_user(team_id, slack_user_id)
    user = maybe_refresh_profile(user)
    today = Period.today(Accounts.time_zone(user))

    blocks =
      user
      |> Calendar.list_user_events_on(today)
      |> Repo.preload(:channels)
      |> HomeTab.render(user, today)

    SlackAPI.post("views.publish", %{
      user_id: slack_user_id,
      view: %{type: "home", blocks: blocks}
    })
  end

  defp maybe_refresh_profile(%User{profile_synced_at: synced_at} = user) do
    if is_nil(synced_at) or
         DateTime.diff(DateTime.utc_now(), synced_at) > @profile_max_age_seconds do
      refresh_profile(user)
    else
      user
    end
  end

  # A failure here shouldn't stop the Home tab: it falls back to the stored
  # (or default) time zone and tries again next time.
  defp refresh_profile(user) do
    with {:ok, %{"user" => profile}} <- SlackAPI.get("users.info", %{user: user.slack_user_id}),
         {:ok, user} <-
           Accounts.get_or_create_user(user.slack_team_id, user.slack_user_id, %{
             name: profile_name(profile),
             time_zone: profile["tz"],
             profile_synced_at: DateTime.utc_now()
           }) do
      user
    else
      error ->
        Logger.warning("Couldn't refresh #{user.slack_user_id}'s profile: #{inspect(error)}")
        user
    end
  end

  defp profile_name(profile) do
    get_in(profile, ["profile", "display_name"])
    |> case do
      name when name in [nil, ""] -> profile["real_name"] || profile["name"]
      name -> name
    end
  end
end
