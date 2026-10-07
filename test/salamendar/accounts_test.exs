defmodule Salamendar.AccountsTest do
  use Salamendar.DataCase, async: true

  alias Salamendar.Accounts
  alias Salamendar.Accounts.User

  describe "get_or_create_user/3" do
    test "creates a user with a UUIDv7 primary key" do
      assert {:ok, %User{} = user} =
               Accounts.get_or_create_user("T1", "U1", %{name: "Ada", time_zone: "Europe/London"})

      assert user.slack_team_id == "T1"
      assert user.slack_user_id == "U1"
      assert user.name == "Ada"
      assert user.time_zone == "Europe/London"
      assert {:ok, <<_::48, 7::4, _::76>>} = Ecto.UUID.dump(user.id)
    end

    test "returns the existing user and updates given attributes" do
      {:ok, original} = Accounts.get_or_create_user("T1", "U1", %{name: "Ada", time_zone: "UTC"})
      {:ok, updated} = Accounts.get_or_create_user("T1", "U1", %{name: "Ada L."})

      assert updated.id == original.id
      assert updated.name == "Ada L."
      assert updated.time_zone == "UTC"
      assert Repo.aggregate(User, :count) == 1
    end

    test "treats the same user ID in different workspaces as different users" do
      {:ok, a} = Accounts.get_or_create_user("T1", "U1")
      {:ok, b} = Accounts.get_or_create_user("T2", "U1")

      assert a.id != b.id
    end

    test "requires Slack IDs" do
      assert {:error, changeset} = Accounts.get_or_create_user(nil, "U1")
      assert %{slack_team_id: ["can't be blank"]} = errors_on(changeset)
    end
  end
end
