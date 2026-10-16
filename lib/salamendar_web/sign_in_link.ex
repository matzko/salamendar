defmodule SalamendarWeb.SignInLink do
  @moduledoc """
  Sign-in links sent from Slack: `<web_url>/auth/slack?token=…`, where the
  token is a signed `Phoenix.Token` holding the user's ID.

  Slack only shows a link to the user it's for (the Home tab is published
  per user, and command replies are ephemeral), so holding the link is
  proof enough of who you are. `SalamendarWeb.AuthController` swaps it for
  a session cookie.
  """

  alias Salamendar.Accounts.User

  @salt "slack link"

  # The Home tab is republished whenever it's opened, so a link is at most
  # as old as the user's last visit.
  @max_age 24 * 60 * 60

  @doc """
  A sign-in link for `user`. With `:return_to` (a local path such as
  `"/?channel=C1"`), the browser lands there after signing in.
  """
  @spec url(User.t(), keyword()) :: String.t()
  def url(%User{id: user_id}, opts \\ []) do
    token = Phoenix.Token.sign(SalamendarWeb.Endpoint, @salt, user_id)
    query = [token: token] ++ Keyword.take(opts, [:return_to])

    "#{Application.fetch_env!(:salamendar, :web_url)}/auth/slack?#{URI.encode_query(query)}"
  end

  @doc """
  The user ID in a link's token, if it's genuine and not yet expired.
  """
  @spec verify(String.t()) :: {:ok, Ecto.UUID.t()} | {:error, :expired | :invalid | :missing}
  def verify(token) when is_binary(token) do
    Phoenix.Token.verify(SalamendarWeb.Endpoint, @salt, token, max_age: @max_age)
  end
end
