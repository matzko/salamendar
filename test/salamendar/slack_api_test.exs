defmodule Salamendar.SlackAPITest do
  use ExUnit.Case, async: true

  import Mox

  alias Salamendar.SlackAPI

  setup :verify_on_exit!

  test "calls the configured implementation" do
    expect(SlackAPI.Mock, :post, fn "chat.postMessage", %{channel: "C1"} ->
      {:ok, %{"ok" => true}}
    end)

    expect(SlackAPI.Mock, :get, fn "users.info", %{} -> {:error, "user_not_found"} end)

    expect(SlackAPI.Mock, :stream, fn "conversations.members", %{channel: "C1"}, "members" ->
      ["U1"]
    end)

    assert {:ok, _} = SlackAPI.post("chat.postMessage", %{channel: "C1"})
    assert {:error, "user_not_found"} = SlackAPI.get("users.info")
    assert ["U1"] = SlackAPI.stream("conversations.members", %{channel: "C1"}, "members")
  end
end
