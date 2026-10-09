Mox.defmock(Salamendar.SlackAPI.Mock, for: Salamendar.SlackAPI)

ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(Salamendar.Repo, :manual)
