defmodule SalamendarWeb.CoreComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.Component, only: [sigil_H: 2, to_form: 2]
  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]
  import SalamendarWeb.CoreComponents

  # A form over `params`. Fields present in `params` count as used, so their
  # errors show.
  defp event_form(params, errors \\ []), do: to_form(params, as: :event, errors: errors)

  defp render_input(attrs) do
    assigns = %{attrs: attrs}

    rendered_to_string(~H"""
    <.input {@attrs} />
    """)
  end

  describe "input/1" do
    test "renders a text input with its label and value" do
      html = render_input(field: event_form(%{"title" => "Standup"})[:title], label: "Title")

      assert html =~ ~s(<label for="event_title" class="field-label">Title</label>)
      assert html =~ ~s(name="event[title]")
      assert html =~ ~s(value="Standup")
    end

    test "shows errors only for used fields" do
      error = [title: {"can't be blank", [validation: :required]}]

      html = render_input(field: event_form(%{"title" => ""}, error)[:title])
      assert html =~ "can&#39;t be blank"
      assert html =~ "field-input-error"

      # Not in the params, so not used yet.
      refute render_input(field: event_form(%{}, error)[:title]) =~ "blank"
    end

    test "emoji adds the hook, the button and an ignored popup to a text input" do
      html = render_input(field: event_form(%{"title" => "Standup"})[:title], emoji: true)

      assert html =~ ~s(class="field field-emoji" id="event_title-emoji" phx-hook="EmojiInput")
      assert html =~ ~s(<div id="event_title-emoji-ui" phx-update="ignore">)
      assert html =~ ~s(aria-label="Insert emoji")
      assert html =~ ~s(aria-controls="event_title-emoji-popup")
      assert html =~ ~s(<div id="event_title-emoji-popup" class="emoji-popup" hidden)
      assert html =~ ~s(name="event[title]")
    end

    test "emoji works on a textarea" do
      html =
        render_input(
          field: event_form(%{"description" => "Notes"})[:description],
          type: "textarea",
          emoji: true
        )

      assert html =~ ~s(phx-hook="EmojiInput")
      assert html =~ ~s(Notes</textarea>)
    end

    test "inputs without emoji, or of other types, get none of it" do
      f = event_form(%{"title" => "Standup", "day" => "2026-10-14"})

      for html <- [
            render_input(field: f[:title]),
            render_input(field: f[:day], type: "date", emoji: true)
          ] do
        refute html =~ "phx-hook"
        refute html =~ "emoji"
      end
    end

    test "fills in error placeholders" do
      error = [title: {"should be at most %{count} character(s)", [count: 255]}]
      assert render_input(field: event_form(%{"title" => "x"}, error)[:title]) =~ "at most 255"
    end

    test "renders date and datetime-local inputs" do
      f = event_form(%{"start" => "2026-10-14T09:00", "day" => "2026-10-14"})

      assert render_input(field: f[:start], type: "datetime-local") =~
               ~s(type="datetime-local")

      assert render_input(field: f[:day], type: "date") =~ ~s(value="2026-10-14")
    end

    test "renders a checkbox with a hidden false value" do
      html =
        render_input(
          field: event_form(%{"all_day" => "true"})[:all_day],
          type: "checkbox",
          label: "All day"
        )

      assert html =~ ~s(type="hidden" name="event[all_day]" value="false")
      assert html =~ ~r/type="checkbox"[^>]*value="true"[^>]*checked/
    end

    test "renders a checkgroup with the selected values checked" do
      html =
        render_input(
          field: event_form(%{"channel_ids" => ["b"]})[:channel_ids],
          type: "checkgroup",
          label: "Channels",
          options: [{"#a", "a"}, {"#b", "b"}]
        )

      assert html =~ ~s(<legend class="field-label">Channels</legend>)
      assert html =~ ~s(type="hidden" name="event[channel_ids][]" value="")
      refute html =~ ~r/value="a"[^>]*checked/
      assert html =~ ~r/value="b"[^>]*checked/
    end

    test "renders a select with a prompt and grouped options" do
      html =
        render_input(
          field: event_form(%{"label_id" => "b"})[:label_id],
          type: "select",
          label: "Label",
          prompt: "None",
          options: [{"Shared", [{"Holiday", "a"}]}, {"Mine", [{"On call", "b"}]}]
        )

      assert html =~ ~s(<label for="event_label_id" class="field-label">Label</label>)
      assert html =~ ~s(<select id="event_label_id" name="event[label_id]")
      assert html =~ ~s(<option value="">None</option>)
      assert html =~ ~s(<optgroup label="Shared"><option value="a">Holiday</option></optgroup>)
      assert html =~ ~s(<option selected value="b">On call</option>)
    end

    test "renders a textarea" do
      html =
        render_input(
          field: event_form(%{"description" => "Notes"})[:description],
          type: "textarea"
        )

      assert html =~ ~r{<textarea[^>]*name="event\[description\]"[^>]*>\nNotes</textarea>}
    end
  end

  describe "button/1" do
    test "renders a button with its variant" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.button type="submit" variant="primary">Save</.button>
        """)

      assert html =~ ~r{<button class="button button-primary" type="submit">\s*Save\s*</button>}
    end

    test "renders a link styled as a button" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.button href="/settings">Settings</.button>
        """)

      assert html =~ ~r{<a href="/settings" class="button">\s*Settings\s*</a>}
    end
  end
end
