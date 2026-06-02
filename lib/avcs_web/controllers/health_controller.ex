defmodule AvcsWeb.HealthController do
  use AvcsWeb, :controller

  alias AvcsWeb.ApiResponse

  def show(conn, _params) do
    ApiResponse.ok(conn, %{status: "ok"})
  end
end
