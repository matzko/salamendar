defmodule Salamendar.LabelsTest do
  use Salamendar.DataCase, async: true

  alias Salamendar.{Accounts, Calendar, Channels, Labels}
  alias Salamendar.Calendar.Event
  alias Salamendar.Labels.Label

  defp user!(slack_user_id, team_id \\ "TLB1") do
    {:ok, user} = Accounts.get_or_create_user(team_id, slack_user_id)
    user
  end

  defp label!(user, scope, name, color \\ "red") do
    {:ok, label} = Labels.create_label(user, %{name: name, color: color}, scope)
    label
  end

  defp channel!(slack_channel_id) do
    {:ok, channel} = Channels.upsert_channel("TLB1", slack_channel_id, %{})
    {:ok, channel} = Channels.enable_calendar(channel)
    channel
  end

  defp event!(owner, label, channels) do
    {:ok, event, _} =
      Calendar.create_event(
        owner,
        %{
          title: "On call",
          time_zone: "Etc/UTC",
          starts_at: ~U[2026-10-10 14:00:00Z],
          ends_at: ~U[2026-10-10 15:00:00Z],
          label_id: label.id
        },
        channels
      )

    event
  end

  defp names(labels), do: Enum.map(labels, & &1.name)

  describe "list_labels/1" do
    test "the workspace's shared labels and the user's own, each sorted by name" do
      user = user!("U1")
      other = user!("U2")
      label!(user, :shared, "holiday")
      label!(other, :shared, "Deploys")
      label!(user, :personal, "On call")
      label!(user, :personal, "focus")
      label!(other, :personal, "Theirs")
      label!(user!("U3", "TLB2"), :shared, "Elsewhere")

      assert %{shared: shared, mine: mine} = Labels.list_labels(user)
      assert names(shared) == ["Deploys", "holiday"]
      assert names(mine) == ["focus", "On call"]
    end

    test "empty groups for a user with no labels" do
      assert Labels.list_labels(user!("U1")) == %{shared: [], mine: []}
    end
  end

  describe "get_label/2" do
    test "finds labels the user can use, and nil otherwise" do
      user = user!("U1")
      mine = label!(user, :personal, "On call")
      ours = label!(user!("U2"), :shared, "Holiday")
      theirs = label!(user!("U2"), :personal, "Theirs")
      elsewhere = label!(user!("U3", "TLB2"), :shared, "Elsewhere")

      assert Labels.get_label(user, mine.id).id == mine.id
      assert Labels.get_label(user, ours.id).id == ours.id
      assert Labels.get_label(user, theirs.id) == nil
      assert Labels.get_label(user, elsewhere.id) == nil
      assert Labels.get_label(user, Ecto.UUID.generate()) == nil
      assert Labels.get_label(user, "nope") == nil
    end
  end

  describe "create_label/3" do
    test "creates personal and shared labels" do
      user = user!("U1")

      assert {:ok, %Label{} = mine} =
               Labels.create_label(user, %{name: "On call", color: "red"}, :personal)

      assert mine.user_id == user.id
      assert mine.created_by_id == user.id
      assert mine.slack_team_id == "TLB1"

      assert {:ok, %Label{} = ours} =
               Labels.create_label(user, %{name: "Holiday", color: "green"}, :shared)

      assert ours.user_id == nil
      assert ours.created_by_id == user.id
    end

    test "a name can be used once in each scope, ignoring case" do
      user = user!("U1")
      label!(user, :personal, "On call")
      label!(user, :shared, "On call")

      assert {:error, changeset} =
               Labels.create_label(user, %{name: "ON CALL", color: "red"}, :personal)

      assert %{name: ["is already used"]} = errors_on(changeset)

      assert {:error, changeset} =
               Labels.create_label(user!("U2"), %{name: "on call", color: "red"}, :shared)

      assert %{name: ["is already used"]} = errors_on(changeset)
    end

    test "rejects an unknown color" do
      assert {:error, changeset} =
               Labels.create_label(user!("U1"), %{name: "On call", color: "x"}, :personal)

      assert %{color: ["is invalid"]} = errors_on(changeset)
    end
  end

  describe "who can change a label" do
    test "a personal label: only its owner" do
      owner = user!("U1")
      label = label!(owner, :personal, "On call")

      assert Labels.can_change?(owner, label)
      refute Labels.can_change?(user!("U2"), label)

      assert {:error, :forbidden} = Labels.update_label(user!("U2"), label, %{color: "blue"})
      assert {:error, :forbidden} = Labels.delete_label(user!("U2"), label)

      assert {:ok, %Label{color: "blue"}, []} =
               Labels.update_label(owner, label, %{color: "blue"})
    end

    test "a shared label: its creator, then anyone in the workspace once they're gone" do
      creator = user!("U1")
      other = user!("U2")
      label = label!(creator, :shared, "Holiday")

      assert Labels.can_change?(creator, label)
      refute Labels.can_change?(other, label)
      assert {:error, :forbidden} = Labels.update_label(other, label, %{name: "Holidays"})

      Repo.delete!(creator)
      label = Repo.reload!(label)

      assert Labels.can_change?(other, label)
      refute Labels.can_change?(user!("U3", "TLB2"), label)

      assert {:ok, %Label{name: "Holidays"}, []} =
               Labels.update_label(other, label, %{name: "Holidays"})
    end

    test "a stale struct can't bypass the check" do
      creator = user!("U1")
      other = user!("U2")
      label = label!(creator, :shared, "Holiday")

      # Looks orphaned to the caller, but the row still has its creator.
      assert {:error, :forbidden} =
               Labels.delete_label(other, %{label | created_by_id: nil})
    end

    test "a deleted label is not found" do
      owner = user!("U1")
      label = label!(owner, :personal, "On call")
      {:ok, _, _} = Labels.delete_label(owner, label)

      assert {:error, :not_found} = Labels.update_label(owner, label, %{color: "blue"})
      assert {:error, :not_found} = Labels.delete_label(owner, label)
    end
  end

  describe "update_label/3" do
    test "returns the channels of the label's events, once each" do
      owner = user!("U1")
      a = channel!("C1")
      b = channel!("C2")
      label = label!(owner, :shared, "Holiday")
      event!(owner, label, [a, b])
      event!(user!("U2"), label, [b])
      event!(owner, label!(owner, :personal, "Other"), [channel!("C3")])

      assert {:ok, _label, affected} = Labels.update_label(owner, label, %{color: "blue"})
      assert Enum.sort(affected) == Enum.sort([a.id, b.id])
    end

    test "a duplicate name is a changeset error" do
      owner = user!("U1")
      label!(owner, :personal, "On call")
      label = label!(owner, :personal, "Focus")

      assert {:error, changeset} = Labels.update_label(owner, label, %{name: "on call"})
      assert %{name: ["is already used"]} = errors_on(changeset)
    end
  end

  describe "delete_label/2" do
    test "leaves its events unlabeled and returns their channels" do
      owner = user!("U1")
      a = channel!("C1")
      label = label!(owner, :personal, "On call")
      event = event!(owner, label, [a])

      assert {:ok, %Label{}, [channel_id]} = Labels.delete_label(owner, label)
      assert channel_id == a.id
      assert Repo.get(Label, label.id) == nil
      assert %Event{label_id: nil} = Repo.get(Event, event.id)
    end
  end

  test "count_events/1 counts each label's events" do
    owner = user!("U1")
    a = channel!("C1")
    holiday = label!(owner, :shared, "Holiday")
    on_call = label!(owner, :personal, "On call")
    unused = label!(owner, :personal, "Unused")
    assert Labels.count_events([holiday]) == %{}

    event!(owner, holiday, [a])
    event!(user!("U2"), holiday, [a])
    event!(owner, on_call, [a])

    assert Labels.count_events([holiday, on_call, unused]) == %{holiday.id => 2, on_call.id => 1}
  end
end
