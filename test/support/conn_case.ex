defmodule SalamendarWeb.ConnCase do
  @moduledoc """
  Test case for tests that make requests to the endpoint, including
  LiveView tests. Like `Salamendar.DataCase`, each test runs in a sandboxed
  transaction, which LiveView processes share through `$callers`.

  As in `Salamendar.DataCase`, each module uses its own Slack team IDs.
  """

  use ExUnit.CaseTemplate

  alias Ecto.Adapters.SQL.Sandbox

  using do
    quote do
      @endpoint SalamendarWeb.Endpoint

      use SalamendarWeb, :verified_routes

      import Plug.Conn
      import Phoenix.ConnTest
      import SalamendarWeb.ConnCase
    end
  end

  setup tags do
    pid = Sandbox.start_owner!(Salamendar.Repo, shared: not tags[:async])
    on_exit(fn -> Sandbox.stop_owner(pid) end)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  @doc """
  Puts `user` in `conn`'s session, as signing in would.
  """
  @spec sign_in(Plug.Conn.t(), Salamendar.Accounts.User.t()) :: Plug.Conn.t()
  def sign_in(conn, user), do: Phoenix.ConnTest.init_test_session(conn, user_id: user.id)
end
