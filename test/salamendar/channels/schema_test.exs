defmodule Salamendar.Channels.SchemaTest do
  use Salamendar.DataCase, async: true

  alias Salamendar.Accounts
  alias Salamendar.Channels.{Channel, Membership}

  defp insert_channel(attrs \\ %{}) do
    %Channel{}
    |> Channel.changeset(Map.merge(%{slack_team_id: "TS1", slack_channel_id: "C1"}, attrs))
    |> Repo.insert()
  end

  describe "Channel" do
    test "applies defaults" do
      assert {:ok, channel} = insert_channel()
      assert channel.week_start == 0
      refute channel.calendar_enabled
      refute channel.is_private
    end

    test "is unique per workspace and channel ID" do
      assert {:ok, _} = insert_channel()
      assert {:error, changeset} = insert_channel()
      assert %{slack_team_id: ["has already been taken"]} = errors_on(changeset)
    end

    test "validates week_start" do
      assert {:error, changeset} = insert_channel(%{week_start: 7})
      assert %{week_start: [_]} = errors_on(changeset)
    end
  end

  describe "Membership" do
    test "is deleted with its user or channel" do
      {:ok, user} = Accounts.get_or_create_user("TS1", "U1")
      {:ok, channel} = insert_channel()
      {:ok, other} = insert_channel(%{slack_channel_id: "C2"})

      Repo.insert!(%Membership{user_id: user.id, channel_id: channel.id})
      Repo.insert!(%Membership{user_id: user.id, channel_id: other.id})

      Repo.delete!(channel)
      assert Repo.aggregate(Membership, :count) == 1

      Repo.delete!(user)
      assert Repo.aggregate(Membership, :count) == 0
    end
  end
end
