defmodule SalamendarWeb.SettingsLiveTest do
  use SalamendarWeb.ConnCase, async: true
  use Oban.Testing, repo: Salamendar.Repo

  import Phoenix.LiveViewTest

  alias Salamendar.{Accounts, Calendar, Channels, Colors, Labels, Repo}
  alias Salamendar.Calendar.{Changes, Event}
  alias Salamendar.Labels.Label
  alias Salamendar.Workers.PublishHome

  defp user!(slack_user_id, attrs) do
    {:ok, user} = Accounts.get_or_create_user("TST1", slack_user_id, attrs)
    user
  end

  defp label!(user, scope, name, color \\ "red") do
    {:ok, label} = Labels.create_label(user, %{name: name, color: color}, scope)
    label
  end

  defp event!(owner, channel, label \\ nil) do
    {:ok, event, _} =
      Calendar.create_event(
        owner,
        %{
          title: "Standup",
          time_zone: "Etc/UTC",
          starts_at: ~U[2026-10-14 14:00:00Z],
          ends_at: ~U[2026-10-14 14:15:00Z],
          label_id: label && label.id
        },
        [channel]
      )

    event
  end

  setup %{conn: conn} do
    viewer = user!("U1", %{name: "Ada"})
    other = user!("U2", %{name: "Grace"})
    {:ok, team} = Channels.upsert_channel("TST1", "C1", %{name: "team"})
    {:ok, team} = Channels.enable_calendar(team)
    for member <- [viewer, other], do: :ok = Channels.add_member(team, member)
    %{conn: sign_in(conn, viewer), viewer: viewer, other: other, team: team}
  end

  test "sends visitors without a session to the expired page" do
    assert {:error, {:redirect, %{to: "/auth/expired"}}} = live(build_conn(), ~p"/settings")
  end

  test "links to and from the calendar", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    assert has_element?(view, ~s(a[href="/settings"]), "Settings")

    {:ok, view, _html} = live(conn, ~p"/settings")
    assert has_element?(view, ~s(a[href="/"]), "Back to the calendar")
  end

  describe "your color" do
    test "shows the current color, derived when none was picked", %{conn: conn, viewer: viewer} do
      {:ok, view, _html} = live(conn, ~p"/settings")
      key = Colors.for_user(viewer).key
      assert has_element?(view, "#color-form input[value=#{key}][checked]")
    end

    test "picking one saves it and refreshes the user's events", %{
      conn: conn,
      viewer: viewer,
      other: other,
      team: team
    } do
      event!(viewer, team)
      :ok = Changes.subscribe(other)
      {:ok, view, _html} = live(conn, ~p"/settings")

      view |> form("#color-form", %{color: "purple"}) |> render_change()

      assert Repo.reload!(viewer).color == "purple"
      assert has_element?(view, "#color-form input[value=purple][checked]")
      assert_receive :calendar_changed
      assert_enqueued(worker: PublishHome, args: %{team_id: "TST1", slack_user_id: "U1"})
    end

    test "refuses an unknown color", %{conn: conn, viewer: viewer} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      html = render_change(view, "set_color", %{"color" => "chartreuse"})

      assert html =~ "Couldn&#39;t change your color."
      assert Repo.reload!(viewer).color == nil
    end
  end

  describe "labels" do
    test "lists shared labels and the viewer's own", %{conn: conn, viewer: viewer, other: other} do
      label!(other, :shared, "Holiday")
      label!(viewer, :personal, "On call")
      label!(other, :personal, "Theirs")

      {:ok, view, _html} = live(conn, ~p"/settings")

      assert has_element?(view, "#labels-shared .label-row", "Holiday")
      assert has_element?(view, "#labels-personal .label-row", "On call")
      refute render(view) =~ "Theirs"
    end

    test "adds labels in both scopes", %{conn: conn, viewer: viewer} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      for scope <- ~w(shared personal) do
        assert has_element?(view, "#new-#{scope}_name-emoji[phx-hook=EmojiInput]")
      end

      view
      |> form("#new-shared", %{label: %{name: "Holiday", color: "green"}})
      |> render_submit(%{scope: "shared"})

      view
      |> form("#new-personal", %{label: %{name: "On call", color: "red"}})
      |> render_submit(%{scope: "personal"})

      assert %{shared: [%Label{name: "Holiday", color: "green"}], mine: [%Label{name: "On call"}]} =
               Labels.list_labels(viewer)

      assert has_element?(view, "#labels-shared .label-row", "Holiday")
      assert has_element?(view, "#labels-personal .label-row", "On call")
      # The form is reset.
      refute has_element?(view, "#new-shared input[name='label[name]'][value]")
    end

    test "a duplicate name shows the error on the field", %{conn: conn, viewer: viewer} do
      label!(viewer, :personal, "On call")
      {:ok, view, _html} = live(conn, ~p"/settings")

      html =
        view
        |> form("#new-personal", %{label: %{name: "on call", color: "red"}})
        |> render_submit(%{scope: "personal"})

      assert html =~ "is already used"
      assert %{mine: [_]} = Labels.list_labels(viewer)
    end

    test "a missing color shows an error", %{conn: conn, viewer: viewer} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      html =
        view
        |> form("#new-personal", %{label: %{name: "On call"}})
        |> render_submit(%{scope: "personal"})

      assert html =~ "can&#39;t be blank"
      assert %{mine: []} = Labels.list_labels(viewer)
    end

    test "renaming and recoloring tells open calendars", %{
      conn: conn,
      viewer: viewer,
      other: other,
      team: team
    } do
      label = label!(viewer, :shared, "Holiday")
      event!(other, team, label)
      :ok = Changes.subscribe(other)
      {:ok, view, _html} = live(conn, ~p"/settings")

      view |> element("#label-#{label.id} button", "Edit") |> render_click()
      assert has_element?(view, "#edit-label_name-emoji[phx-hook=EmojiInput]")

      view
      |> form("#edit-label", %{label: %{name: "Holidays", color: "blue"}})
      |> render_submit()

      assert %Label{name: "Holidays", color: "blue"} = Repo.reload!(label)
      refute has_element?(view, "#edit-label")
      assert has_element?(view, "#label-#{label.id}", "Holidays")
      assert_receive :calendar_changed
      assert_enqueued(worker: PublishHome, args: %{slack_user_id: "U1"})
    end

    test "Cancel leaves a label unchanged", %{conn: conn, viewer: viewer} do
      label = label!(viewer, :personal, "On call")
      {:ok, view, _html} = live(conn, ~p"/settings")

      view |> element("#label-#{label.id} button", "Edit") |> render_click()
      view |> element("#edit-label button", "Cancel") |> render_click()

      refute has_element?(view, "#edit-label")
      assert %Label{name: "On call"} = Repo.reload!(label)
    end

    test "deleting says how many events lose the color and leaves them unlabeled", %{
      conn: conn,
      viewer: viewer,
      team: team
    } do
      label = label!(viewer, :personal, "On call")
      event = event!(viewer, team, label)
      event!(viewer, team, label)
      :ok = Changes.subscribe(viewer)
      {:ok, view, _html} = live(conn, ~p"/settings")

      delete = element(view, "#label-#{label.id} button", "Delete")
      assert render(delete) =~ "2 events will lose this color."

      render_click(delete)

      assert Repo.get(Label, label.id) == nil
      assert %Event{label_id: nil} = Repo.reload!(event)
      refute has_element?(view, "#label-#{label.id}")
      assert render(view) =~ "Deleted “On call”."
      assert_receive :calendar_changed
    end

    test "deleting a shared label warns that anyone's events may lose it", %{
      conn: conn,
      viewer: viewer,
      other: other,
      team: team
    } do
      label = label!(viewer, :shared, "Holiday")
      event!(other, team, label)
      {:ok, view, _html} = live(conn, ~p"/settings")

      assert view |> element("#label-#{label.id} button", "Delete") |> render() =~
               "1 event will lose this color. Shared labels can be on anyone&#39;s events."
    end

    test "someone else's shared label has no controls and can't be changed", %{
      conn: conn,
      other: other
    } do
      label = label!(other, :shared, "Holiday")
      {:ok, view, _html} = live(conn, ~p"/settings")

      refute has_element?(view, "#label-#{label.id} button")
      assert has_element?(view, "#label-#{label.id}", "Made by Grace")

      render_click(view, "edit", %{"id" => label.id})
      refute has_element?(view, "#edit-label")

      html = render_click(view, "delete", %{"id" => label.id})
      assert html =~ "Only the person who made that label can change it."
      assert Repo.reload!(label)
    end

    test "a shared label gets controls once its creator is gone", %{conn: conn, other: other} do
      label = label!(other, :shared, "Holiday")
      Repo.delete!(other)
      {:ok, view, _html} = live(conn, ~p"/settings")

      assert has_element?(view, "#label-#{label.id} button", "Edit")
      assert has_element?(view, "#label-#{label.id} button", "Delete")
    end

    test "a label deleted meanwhile says so", %{conn: conn, viewer: viewer} do
      label = label!(viewer, :personal, "On call")
      {:ok, view, _html} = live(conn, ~p"/settings")
      {:ok, _, _} = Labels.delete_label(viewer, label)

      html = view |> element("#label-#{label.id} button", "Delete") |> render_click()

      assert html =~ "That label was deleted."
      refute has_element?(view, "#label-#{label.id}")
    end
  end
end
