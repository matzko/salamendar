defmodule Salamendar.ApplicationTest do
  use ExUnit.Case, async: true

  test "the Slack supervisor is not started under test" do
    refute Enum.any?(Supervisor.which_children(Salamendar.Supervisor), fn {id, _, _, _} ->
             id == Slack.Supervisor
           end)
  end
end
