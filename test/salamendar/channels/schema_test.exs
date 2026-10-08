defmodule Salamendar.Channels.SchemaTest do
  use Salamendar.DataCase, async: true

  alias Salamendar.Accounts
  alias Salamendar.Channels.{Canvas, Channel, Membership}

  defp insert_channel(attrs \\ %{}) do
    %Channel{}
    |> Channel.changeset(Map.merge(%{slack_team_id: "T1", slack_channel_id: "C1"}, attrs))
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

    test "validates week_start and time zone" do
      assert {:error, changeset} = insert_channel(%{week_start: 7, time_zone: "Nowhere"})

      assert %{week_start: [_], time_zone: ["is not a valid time zone"]} =
               errors_on(changeset)
    end
  end

  describe "Canvas" do
    setup do
      {:ok, channel} = insert_channel()
      %{channel: channel}
    end

    test "allows one canvas of each kind per channel", %{channel: channel} do
      insert = fn kind ->
        %Canvas{channel_id: channel.id} |> Canvas.changeset(%{kind: kind}) |> Repo.insert()
      end

      assert {:ok, _} = insert.(:month)
      assert {:ok, _} = insert.(:week)
      assert {:error, changeset} = insert.(:month)
      assert %{channel_id: ["has already been taken"]} = errors_on(changeset)
    end

    test "the database rejects unknown kinds", %{channel: channel} do
      now = DateTime.utc_now()

      row = %{
        id: Ecto.UUID.dump!(Ecto.UUID.generate()),
        channel_id: Ecto.UUID.dump!(channel.id),
        kind: "day",
        inserted_at: now,
        updated_at: now
      }

      assert_raise Postgrex.Error, ~r/channel_canvases_kind/, fn ->
        Repo.insert_all("channel_canvases", [row])
      end
    end

    test "is deleted with its channel", %{channel: channel} do
      Repo.insert!(%Canvas{channel_id: channel.id, kind: :month})
      Repo.delete!(channel)
      assert Repo.aggregate(Canvas, :count) == 0
    end
  end

  describe "Membership" do
    test "is deleted with its user or channel" do
      {:ok, user} = Accounts.get_or_create_user("T1", "U1")
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
