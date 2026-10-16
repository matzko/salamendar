defmodule SalamendarWeb.ConnCase do
  @moduledoc """
  Test case for tests that make requests to the endpoint, including
  LiveView tests. Like `Salamendar.DataCase`, each test runs in a sandboxed
  transaction, which LiveView processes share through `$callers`.
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
end
