defmodule Salamendar.Labels do
  @moduledoc """
  Labels: names and colors that events are tagged with.

  A personal label belongs to one user and can go on their events only. A
  shared label belongs to the workspace and can go on anyone's. A personal
  label can be changed only by its owner; a shared one only by whoever made
  it, or by anyone once they're gone, so it can't get stuck.

  Changing or deleting a label returns the IDs of the channels its events
  are in, so callers can tell open calendars to refresh. Nothing here calls
  Slack.
  """

  import Ecto.Query

  alias Salamendar.Accounts.User
  alias Salamendar.Calendar.Event
  alias Salamendar.Labels.Label
  alias Salamendar.Repo

  @type affected_channel_ids :: [Ecto.UUID.t()]

  @doc """
  The labels `user` can use: their workspace's shared labels and their own
  personal ones, each sorted by name.
  """
  @spec list_labels(User.t()) :: %{shared: [Label.t()], mine: [Label.t()]}
  def list_labels(%User{} = user) do
    labels =
      from(l in usable(user), order_by: [fragment("lower(?)", l.name), l.id])
      |> Repo.all()

    {shared, mine} = Enum.split_with(labels, &is_nil(&1.user_id))
    %{shared: shared, mine: mine}
  end

  @doc """
  The label with `id` if `user` can use it, otherwise (or if `id` isn't a
  UUID) `nil`.
  """
  @spec get_label(User.t(), term()) :: Label.t() | nil
  def get_label(%User{} = user, id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> Repo.one(from(l in usable(user), where: l.id == ^id))
      :error -> nil
    end
  end

  @doc """
  Whether `user` may use `label` on their own events.
  """
  @spec usable?(User.t(), Label.t()) :: boolean()
  def usable?(%User{} = user, %Label{} = label) do
    label.slack_team_id == user.slack_team_id and label.user_id in [nil, user.id]
  end

  defp usable(user) do
    from(l in Label,
      where:
        l.slack_team_id == ^user.slack_team_id and (is_nil(l.user_id) or l.user_id == ^user.id)
    )
  end

  @doc """
  Creates a label made by `user`: a personal one of theirs, or one shared
  by their workspace.
  """
  @spec create_label(User.t(), map(), :personal | :shared) ::
          {:ok, Label.t()} | {:error, Ecto.Changeset.t()}
  def create_label(%User{} = user, attrs, scope) when scope in [:personal, :shared] do
    %Label{
      slack_team_id: user.slack_team_id,
      user_id: if(scope == :personal, do: user.id),
      created_by_id: user.id
    }
    |> Label.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Whether `user` may rename, recolor or delete `label`.
  """
  @spec can_change?(User.t(), Label.t()) :: boolean()
  def can_change?(%User{} = user, %Label{} = label) do
    label.slack_team_id == user.slack_team_id and
      case label do
        %Label{user_id: nil, created_by_id: nil} -> true
        %Label{user_id: nil, created_by_id: created_by_id} -> created_by_id == user.id
        %Label{user_id: user_id} -> user_id == user.id
      end
  end

  @doc """
  Changes `label`'s name or color as `user` (see `can_change?/2`).
  """
  @spec update_label(User.t(), Label.t(), map()) ::
          {:ok, Label.t(), affected_channel_ids()}
          | {:error, :forbidden | :not_found | Ecto.Changeset.t()}
  def update_label(%User{} = user, %Label{} = label, attrs) do
    Repo.transact(fn ->
      with {:ok, label} <- lock_changeable_label(user, label),
           {:ok, label} <- label |> Label.changeset(attrs) |> Repo.update() do
        {:ok, {label, channel_ids(label)}}
      end
    end)
    |> unwrap()
  end

  @doc """
  Deletes `label` as `user` (see `can_change?/2`). Its events are left
  unlabeled.
  """
  @spec delete_label(User.t(), Label.t()) ::
          {:ok, Label.t(), affected_channel_ids()} | {:error, :forbidden | :not_found}
  def delete_label(%User{} = user, %Label{} = label) do
    Repo.transact(fn ->
      with {:ok, label} <- lock_changeable_label(user, label) do
        # Before the delete, which unlabels the events.
        channel_ids = channel_ids(label)
        {:ok, {Repo.delete!(label), channel_ids}}
      end
    end)
    |> unwrap()
  end

  @doc """
  How many events have `label`.
  """
  @spec count_events(Label.t()) :: non_neg_integer()
  def count_events(%Label{id: id}) do
    Repo.aggregate(from(e in Event, where: e.label_id == ^id), :count)
  end

  # Reloads the label under a row lock, so the check and the change see the
  # same row.
  defp lock_changeable_label(user, label) do
    case Repo.one(from(l in Label, where: l.id == ^label.id, lock: "FOR UPDATE")) do
      nil ->
        {:error, :not_found}

      %Label{} = label ->
        if can_change?(user, label), do: {:ok, label}, else: {:error, :forbidden}
    end
  end

  defp unwrap({:ok, {label, channel_ids}}), do: {:ok, label, channel_ids}
  defp unwrap(error), do: error

  # The channels of every event with the label, in one query, since a
  # shared label's events can be anywhere.
  defp channel_ids(%Label{id: id}) do
    from(ec in "event_channels",
      join: e in Event,
      on: e.id == ec.event_id,
      where: e.label_id == ^id,
      distinct: true,
      select: type(ec.channel_id, Ecto.UUID)
    )
    |> Repo.all()
  end
end
