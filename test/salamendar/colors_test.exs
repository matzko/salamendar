defmodule Salamendar.ColorsTest do
  use Salamendar.DataCase, async: true

  alias Salamendar.{Accounts, Colors}
  alias Salamendar.Accounts.User
  alias Salamendar.Calendar.Event
  alias Salamendar.Labels.Label

  test "every color has a background, a text color and an emoji" do
    for color <- Colors.all() do
      assert %{key: key, name: name, background: "#" <> _, text: "#" <> _, emoji: emoji} = color
      assert key != "" and name != "" and emoji != ""
      assert Colors.get(key) == color
    end

    assert Colors.keys() == Enum.uniq(Colors.keys())
    assert Colors.get("chartreuse") == nil
  end

  for constraint <- ~w(users_color labels_color) do
    test "the #{constraint} CHECK lists exactly Colors.keys/0" do
      %{rows: [[definition]]} =
        Repo.query!(
          "SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conname = $1",
          [unquote(constraint)]
        )

      keys = for [_, key] <- Regex.scan(~r/'([^']+)'/, definition), do: key
      assert Enum.sort(keys) == Enum.sort(Colors.keys())
    end
  end

  test "an unknown color is rejected by the changeset and by the CHECK" do
    changeset = User.changeset(%User{}, %{slack_team_id: "TCO1", slack_user_id: "U1", color: "x"})
    assert %{color: ["is invalid"]} = errors_on(changeset)

    {:ok, user} = Accounts.get_or_create_user("TCO1", "U1")

    assert_raise Postgrex.Error, ~r/users_color/, fn ->
      Repo.query!("UPDATE users SET color = 'x' WHERE id = $1", [Ecto.UUID.dump!(user.id)])
    end
  end

  describe "for_user/1" do
    test "uses the user's color" do
      assert Colors.for_user(%User{id: Ecto.UUID.generate(), color: "red"}).key == "red"
    end

    test "derives a stable color from the ID when there's none" do
      id = Ecto.UUID.generate()
      color = Colors.for_user(%User{id: id})

      assert color in Colors.all()
      assert Colors.for_user(%User{id: id}) == color
    end
  end

  describe "for_event/1" do
    test "uses the label's color before the owner's" do
      event = %Event{
        label: %Label{color: "red"},
        owner: %User{id: Ecto.UUID.generate(), color: "green"}
      }

      assert Colors.for_event(event).key == "red"
    end

    test "uses the owner's color when the label's is unknown" do
      event = %Event{
        label: %Label{color: "x"},
        owner: %User{id: Ecto.UUID.generate(), color: "green"}
      }

      assert Colors.for_event(event).key == "green"
    end

    test "uses the owner's color without a label" do
      owner = %User{id: Ecto.UUID.generate(), color: "green"}
      assert Colors.for_event(%Event{label: nil, owner: owner}).key == "green"
      assert Colors.for_event(%Event{owner: owner}).key == "green"
    end

    test "falls back to the default without an owner" do
      assert Colors.for_event(%Event{owner: nil}) == Colors.default()
    end
  end
end
