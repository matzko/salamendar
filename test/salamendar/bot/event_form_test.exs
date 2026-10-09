defmodule Salamendar.Bot.EventFormTest do
  use Salamendar.DataCase, async: true
  use Oban.Testing, repo: Salamendar.Repo

  import Mox

  alias Salamendar.{Accounts, Bot, Calendar, Channels}
  alias Salamendar.Calendar.Event
  alias Salamendar.SlackAPI.Mock
  alias Salamendar.Workers.{PublishHome, SyncCanvas}

  setup :verify_on_exit!

  @bot %Slack.Bot{
    id: "B1",
    module: Bot,
    token: "xoxb-test",
    team_id: "TEF1",
    user_id: "UBOT"
  }

  setup do
    {:ok, user} = Accounts.get_or_create_user("TEF1", "U1", %{time_zone: "America/Chicago"})

    %{
      user: user,
      general: channel!("C1", "general", [user]),
      random: channel!("C2", "random", [user])
    }
  end

  defp channel!(slack_channel_id, name, members) do
    {:ok, channel} = Channels.upsert_channel("TEF1", slack_channel_id, %{name: name})
    {:ok, channel} = Channels.enable_calendar(channel)
    for member <- members, do: :ok = Channels.add_member(channel, member)
    channel
  end

  defp event!(owner, channels, attrs \\ %{}) do
    attrs =
      Map.merge(
        %{
          title: "Standup",
          time_zone: "America/Chicago",
          starts_at: ~U[2026-10-12 14:00:00Z],
          ends_at: ~U[2026-10-12 14:15:00Z]
        },
        attrs
      )

    {:ok, event, _} = Calendar.create_event(owner, attrs, channels)
    event
  end

  # A block_actions payload from the Home tab.
  defp block_action(action, user_id \\ "U1") do
    Bot.handle_event(
      "interactive",
      %{
        "type" => "block_actions",
        "user" => %{"id" => user_id, "team_id" => "TEF1"},
        "trigger_id" => "trigger-1",
        "view" => %{"type" => "home"},
        "actions" => [action]
      },
      @bot
    )
  end

  defp menu(value),
    do: %{
      "action_id" => "event_menu",
      "type" => "overflow",
      "selected_option" => %{"value" => value}
    }

  # Expects views.open and sends the view to the test.
  defp expect_view do
    test = self()

    expect(Mock, :post, fn "views.open", %{trigger_id: "trigger-1", view: view} ->
      send(test, {:view, view})
      {:ok, %{"ok" => true}}
    end)
  end

  defp block(view, block_id), do: Enum.find(view.blocks, &(&1[:block_id] == block_id))

  # A view_submission payload with the form's state.
  defp submit(values, opts \\ []) do
    Bot.handle_event(
      "interactive",
      %{
        "type" => "view_submission",
        "user" => %{"id" => Keyword.get(opts, :user_id, "U1")},
        "view" => %{
          "callback_id" => Keyword.get(opts, :callback_id, "event_form"),
          "private_metadata" => Keyword.get(opts, :private_metadata, ""),
          "state" => %{"values" => values}
        }
      },
      @bot
    )
  end

  defp form_values(attrs) do
    %{
      "title" => %{"value" => %{"type" => "plain_text_input", "value" => attrs[:title]}},
      "start" => %{
        "value" => %{
          "type" => "datetimepicker",
          "selected_date_time" => DateTime.to_unix(attrs[:start])
        }
      },
      "end" => %{
        "value" => %{
          "type" => "datetimepicker",
          "selected_date_time" => DateTime.to_unix(attrs[:end])
        }
      },
      "all_day" => %{
        "value" => %{
          "type" => "checkboxes",
          "selected_options" => if(attrs[:all_day], do: [%{"value" => "all_day"}], else: [])
        }
      },
      "channels" => %{
        "value" => %{
          "type" => "multi_static_select",
          "selected_options" => for(id <- attrs[:channel_ids], do: %{"value" => id})
        }
      },
      "description" => %{
        "value" => %{"type" => "plain_text_input", "value" => attrs[:description]}
      }
    }
  end

  describe "opening the form" do
    test "Add event lists the user's calendar channels", %{general: general, random: random} do
      {:ok, _} = Channels.upsert_channel("TEF1", "C3", %{name: "not-enabled"})
      expect_view()

      block_action(%{"action_id" => "add_event", "type" => "button"})

      assert_received {:view, view}
      assert view.callback_id == "event_form"
      assert view.private_metadata == ""

      assert Enum.map(view.blocks, & &1.block_id) ==
               ~w(title start end all_day channels description)

      assert block(view, "channels").element.options == [
               %{text: %{type: "plain_text", text: "#general"}, value: general.id},
               %{text: %{type: "plain_text", text: "#random"}, value: random.id}
             ]

      refute Map.has_key?(block(view, "channels").element, :initial_options)
      assert block(view, "start").element.type == "datetimepicker"
    end

    test "explains when the user has no calendar channels" do
      {:ok, _} = Accounts.get_or_create_user("TEF1", "U2")
      expect_view()

      block_action(%{"action_id" => "add_event", "type" => "button"}, "U2")

      assert_received {:view, view}
      refute Map.has_key?(view, :callback_id)
      assert [%{text: %{text: "You aren't in any channels" <> _}}] = view.blocks
    end

    test "Edit fills in the event", %{user: user, general: general} do
      event = event!(user, [general], %{description: "Daily"})
      expect_view()

      block_action(menu("edit:#{event.id}"))

      assert_received {:view, view}
      assert view.private_metadata == event.id
      assert view.title.text == "Edit event"
      assert block(view, "title").element.initial_value == "Standup"
      assert block(view, "description").element.initial_value == "Daily"
      assert block(view, "start").element.initial_date_time == DateTime.to_unix(event.starts_at)

      assert [%{value: general_id}] = block(view, "channels").element.initial_options
      assert general_id == general.id
    end

    test "Edit of an all-day event checks All day", %{user: user, general: general} do
      event =
        event!(user, [general], %{
          all_day: true,
          start_date: ~D[2026-10-20],
          end_date: ~D[2026-10-23],
          starts_at: nil,
          ends_at: nil
        })

      expect_view()
      block_action(menu("edit:#{event.id}"))

      assert_received {:view, view}
      assert [_] = block(view, "all_day").element.initial_options
      # 9:00 on the first day to 17:00 on the last, in Chicago.
      assert block(view, "start").element.initial_date_time ==
               DateTime.to_unix(~U[2026-10-20 14:00:00Z])

      assert block(view, "end").element.initial_date_time ==
               DateTime.to_unix(~U[2026-10-22 22:00:00Z])
    end

    test "Edit by someone else explains why not", %{user: user, general: general} do
      event = event!(user, [general])
      {:ok, _} = Accounts.get_or_create_user("TEF1", "U2")
      expect_view()

      block_action(menu("edit:#{event.id}"), "U2")

      assert_received {:view, view}
      assert [%{text: %{text: "Only the event's owner can change it."}}] = view.blocks
    end

    test "Delete asks for confirmation", %{user: user, general: general} do
      event = event!(user, [general], %{title: "<Standup>"})
      expect_view()

      block_action(menu("delete:#{event.id}"))

      assert_received {:view, view}
      assert view.callback_id == "delete_event"
      assert view.private_metadata == event.id
      assert [%{text: %{text: "Delete *&lt;Standup&gt;*? This can't be undone."}}] = view.blocks
    end
  end

  describe "submitting the form" do
    test "creates a timed event and schedules the updates", %{user: user, general: general} do
      assert :ok =
               submit(
                 form_values(
                   title: "Review",
                   start: ~U[2026-10-14 18:00:00Z],
                   end: ~U[2026-10-14 19:00:00Z],
                   channel_ids: [general.id],
                   description: ""
                 )
               )

      assert [event] = Repo.all(Event)
      assert event.title == "Review"
      assert event.owner_id == user.id
      assert event.starts_at == ~U[2026-10-14 18:00:00.000000Z]
      assert event.time_zone == "America/Chicago"
      assert is_nil(event.description)

      assert_enqueued(worker: SyncCanvas, args: %{channel_id: general.id})
      assert_enqueued(worker: PublishHome, args: %{team_id: "TEF1", slack_user_id: "U1"})
    end

    test "creates an all-day event from the pickers' local dates", %{general: general} do
      # Oct 20 23:30 to Oct 22 01:00 in Chicago: Oct 20–22 inclusive.
      assert :ok =
               submit(
                 form_values(
                   title: "Offsite",
                   all_day: true,
                   start: ~U[2026-10-21 04:30:00Z],
                   end: ~U[2026-10-22 06:00:00Z],
                   channel_ids: [general.id]
                 )
               )

      assert [%Event{all_day: true, start_date: ~D[2026-10-20], end_date: ~D[2026-10-23]} = event] =
               Repo.all(Event)

      assert is_nil(event.starts_at)
    end

    test "shows changeset errors next to their fields", %{general: general} do
      assert {:ack, %{response_action: "errors", errors: errors}} =
               submit(
                 form_values(
                   title: "Backwards",
                   start: ~U[2026-10-14 19:00:00Z],
                   end: ~U[2026-10-14 18:00:00Z],
                   channel_ids: [general.id]
                 )
               )

      assert errors == %{"end" => "Must be after the start."}

      assert {:ack, %{errors: %{"channels" => "Must include at least one channel."}}} =
               submit(
                 form_values(
                   title: "Nowhere",
                   start: ~U[2026-10-14 18:00:00Z],
                   end: ~U[2026-10-14 19:00:00Z],
                   channel_ids: []
                 )
               )

      assert Repo.aggregate(Event, :count) == 0
      refute_enqueued(worker: PublishHome)
    end

    test "updates an event, syncing old and new channels",
         %{user: user, general: general, random: random} do
      event = event!(user, [general])

      assert :ok =
               submit(
                 form_values(
                   title: "Moved",
                   start: ~U[2026-10-12 14:00:00Z],
                   end: ~U[2026-10-12 14:30:00Z],
                   channel_ids: [random.id]
                 ),
                 private_metadata: event.id
               )

      assert Repo.reload!(event).title == "Moved"
      assert_enqueued(worker: SyncCanvas, args: %{channel_id: general.id})
      assert_enqueued(worker: SyncCanvas, args: %{channel_id: random.id})
    end

    test "only the owner can update", %{user: user, general: general} do
      event = event!(user, [general])
      {:ok, _} = Accounts.get_or_create_user("TEF1", "U2")

      assert {:ack, %{errors: %{"title" => "Only the event's owner can change it."}}} =
               submit(
                 form_values(
                   title: "Mine now",
                   start: ~U[2026-10-12 14:00:00Z],
                   end: ~U[2026-10-12 14:30:00Z],
                   channel_ids: [general.id]
                 ),
                 private_metadata: event.id,
                 user_id: "U2"
               )
    end
  end

  describe "confirming a delete" do
    test "deletes the event and schedules the updates", %{user: user, general: general} do
      event = event!(user, [general])

      assert :ok = submit(%{}, callback_id: "delete_event", private_metadata: event.id)

      refute Repo.get(Event, event.id)
      assert_enqueued(worker: SyncCanvas, args: %{channel_id: general.id})
      assert_enqueued(worker: PublishHome, args: %{slack_user_id: "U1"})
    end

    test "explains an event that's already gone", %{user: user, general: general} do
      event = event!(user, [general])
      Repo.delete!(event)

      assert {:ack, %{response_action: "update", view: %{blocks: [%{text: %{text: text}}]}}} =
               submit(%{}, callback_id: "delete_event", private_metadata: event.id)

      assert text == "This event was already deleted."
    end
  end
end
