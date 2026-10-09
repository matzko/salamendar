defmodule Salamendar.SlackAPI.ClientTest do
  use ExUnit.Case, async: true

  alias Salamendar.SlackAPI.{Client, UnexpectedResponse}

  # Answers every request with `body` as JSON, and sends the conn (with its
  # body read) to the test process.
  defp stub(status \\ 200, body, headers \\ []) do
    test = self()

    Req.Test.stub(Client, fn conn ->
      {:ok, request_body, conn} = Plug.Conn.read_body(conn)
      send(test, {:request, conn, request_body})

      headers
      |> Enum.reduce(conn, fn {name, value}, conn ->
        Plug.Conn.put_resp_header(conn, name, value)
      end)
      |> Plug.Conn.put_status(status)
      |> Req.Test.json(body)
    end)
  end

  test "returns the body when Slack answers ok" do
    stub(%{ok: true, channel: %{id: "C1"}})

    assert {:ok, %{"ok" => true, "channel" => %{"id" => "C1"}}} =
             Client.get("conversations.info", %{channel: "C1"})

    assert_received {:request, conn, ""}
    assert conn.method == "GET"
    assert conn.request_path == "/api/conversations.info"
    assert conn.query_string == "channel=C1"
    assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer xoxb-test"]
  end

  test "posts JSON with a charset" do
    stub(%{ok: true})

    assert {:ok, _} =
             Client.post("canvases.edit", %{canvas_id: "F1", changes: [%{operation: "replace"}]})

    assert_received {:request, conn, body}
    assert conn.method == "POST"
    assert Plug.Conn.get_req_header(conn, "content-type") == ["application/json; charset=utf-8"]

    assert Jason.decode!(body) == %{
             "canvas_id" => "F1",
             "changes" => [%{"operation" => "replace"}]
           }
  end

  test "returns Slack's error code" do
    stub(%{ok: false, error: "canvas_not_found"})
    assert {:error, "canvas_not_found"} = Client.post("canvases.edit", %{})
  end

  test "returns rate limits with the seconds to wait, without retrying" do
    stub(429, %{ok: false, error: "ratelimited"}, [{"retry-after", "17"}])

    assert {:error, :ratelimited, 17} = Client.post("canvases.edit", %{})
    assert_received {:request, _, _}
    refute_received {:request, _, _}
  end

  test "treats an ok: false ratelimited answer as a rate limit" do
    stub(%{ok: false, error: "ratelimited"})
    # No retry-after header: the default wait.
    assert {:error, :ratelimited, 30} = Client.get("users.info", %{})
  end

  test "returns an exception for responses that aren't Slack's" do
    Req.Test.stub(Client, &Plug.Conn.send_resp(&1, 502, "<html>Bad gateway</html>"))
    assert {:error, %UnexpectedResponse{status: 502}} = Client.get("users.info", %{})
  end

  test "respond/2 posts JSON to the response URL without the bot token" do
    test = self()

    Req.Test.stub(Client, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test, {:request, conn, body})
      Plug.Conn.send_resp(conn, 200, "ok")
    end)

    assert :ok =
             Client.respond("https://hooks.slack.com/commands/T1/1/abc", %{
               text: "Hi",
               response_type: "ephemeral"
             })

    assert_received {:request, conn, body}
    assert conn.host == "hooks.slack.com"
    assert Plug.Conn.get_req_header(conn, "authorization") == []
    assert Jason.decode!(body) == %{"text" => "Hi", "response_type" => "ephemeral"}

    Req.Test.stub(Client, &Plug.Conn.send_resp(&1, 404, "expired_url"))

    assert {:error, %UnexpectedResponse{status: 404}} =
             Client.respond("https://hooks.slack.com/x", %{})
  end

  test "returns transport errors" do
    Req.Test.stub(Client, &Req.Test.transport_error(&1, :timeout))
    assert {:error, %Req.TransportError{reason: :timeout}} = Client.get("users.info", %{})
  end
end
