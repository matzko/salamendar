defmodule SalamendarWeb.AuthHTML do
  use SalamendarWeb, :html

  @doc """
  A short notice, such as "This link has expired".
  """
  def message(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="notice">
        <h1>{@heading}</h1>
        <p>{@body}</p>
      </div>
    </Layouts.app>
    """
  end
end
