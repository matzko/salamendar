defmodule Salamendar.Labels.LabelTest do
  use Salamendar.DataCase, async: true

  alias Salamendar.{Accounts, Calendar, Channels}
  alias Salamendar.Calendar.Event
  alias Salamendar.Labels.Label

  defp user!(slack_user_id) do
    {:ok, user} = Accounts.get_or_create_user("TLA1", slack_user_id)
    user
  end

  defp personal(user), do: %Label{slack_team_id: "TLA1", user_id: user.id, created_by_id: user.id}
  defp shared(user), do: %Label{slack_team_id: "TLA1", created_by_id: user.id}

  defp label!(label, name, color \\ "red") do
    label |> Label.changeset(%{name: name, color: color}) |> Repo.insert!()
  end

  defp event!(owner, label) do
    {:ok, channel} = Channels.upsert_channel("TLA1", "C1", %{})
    {:ok, channel} = Channels.enable_calendar(channel)

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
        [channel]
      )

    event
  end

  describe "changeset/2" do
    test "trims the name and requires a name and a color" do
      changeset =
        Label.changeset(%Label{slack_team_id: "TLA1"}, %{name: "  On call ", color: "red"})

      assert changeset.valid?
      assert get_change(changeset, :name) == "On call"

      assert %{name: ["can't be blank"], color: ["can't be blank"]} =
               errors_on(Label.changeset(%Label{slack_team_id: "TLA1"}, %{name: "  "}))
    end

    test "limits the name to 50 characters" do
      changeset =
        Label.changeset(%Label{slack_team_id: "TLA1"}, %{
          name: String.duplicate("a", 51),
          color: "red"
        })

      assert %{name: ["should be at most 50 character(s)"]} = errors_on(changeset)
    end

    test "rejects an unknown color, as does the CHECK" do
      changeset = Label.changeset(%Label{slack_team_id: "TLA1"}, %{name: "On call", color: "x"})
      assert %{color: ["is invalid"]} = errors_on(changeset)

      label = label!(personal(user!("U1")), "On call")

      assert_raise Postgrex.Error, ~r/labels_color/, fn ->
        Repo.query!("UPDATE labels SET color = 'x' WHERE id = $1", [Ecto.UUID.dump!(label.id)])
      end
    end
  end

  describe "names" do
    test "are unique within a scope, ignoring case" do
      user = user!("U1")
      label!(personal(user), "On call")
      label!(shared(user), "Holiday")

      assert {:error, changeset} =
               personal(user)
               |> Label.changeset(%{name: "on call", color: "red"})
               |> Repo.insert()

      assert %{name: ["is already used"]} = errors_on(changeset)

      assert {:error, changeset} =
               shared(user!("U2"))
               |> Label.changeset(%{name: "HOLIDAY", color: "red"})
               |> Repo.insert()

      assert %{name: ["is already used"]} = errors_on(changeset)
    end

    test "can be used once in each scope, and by each user" do
      user = user!("U1")
      label!(personal(user), "On call")
      label!(shared(user), "On call")
      label!(personal(user!("U2")), "On call")
    end
  end

  test "deleting a user deletes their personal labels and keeps the shared ones they made" do
    user = user!("U1")
    mine = label!(personal(user), "On call")
    ours = label!(shared(user), "Holiday")

    Repo.delete!(user)

    assert Repo.get(Label, mine.id) == nil
    assert %Label{created_by_id: nil} = Repo.get(Label, ours.id)
  end

  test "deleting a label leaves its events unlabeled" do
    user = user!("U1")
    label = label!(personal(user), "On call")
    event = event!(user, label)
    assert event.label_id == label.id

    Repo.delete!(label)

    assert %Event{label_id: nil} = Repo.get(Event, event.id)
  end
end
