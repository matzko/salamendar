defmodule Salamendar.DataCase do
  @moduledoc """
  Test case for tests that touch the database. Each test runs inside a
  sandboxed transaction that is rolled back afterwards.

  Async test modules run at the same time, and an insert waits on any
  uncommitted row with the same unique key in another test's transaction;
  two tests doing that in opposite orders deadlock. So each module uses its
  own Slack team IDs (e.g. `"TCA1"` in `CalendarTest`), which every unique
  key in the schema includes.
  """

  use ExUnit.CaseTemplate

  alias Ecto.Adapters.SQL.Sandbox

  using do
    quote do
      alias Salamendar.Repo
      import Ecto.Changeset
      import Salamendar.DataCase
    end
  end

  setup tags do
    pid = Sandbox.start_owner!(Salamendar.Repo, shared: not tags[:async])
    on_exit(fn -> Sandbox.stop_owner(pid) end)
    :ok
  end

  @doc """
  Collects changeset errors into a map of field => messages.
  """
  @spec errors_on(Ecto.Changeset.t()) :: %{atom() => [String.t()]}
  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
