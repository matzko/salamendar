defmodule Salamendar.Repo do
  use Ecto.Repo,
    otp_app: :salamendar,
    adapter: Ecto.Adapters.Postgres
end
