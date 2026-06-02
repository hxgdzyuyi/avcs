defmodule AvcsWeb.ApiResponse do
  @moduledoc false

  import Plug.Conn
  import Phoenix.Controller

  def ok(conn, data) do
    json(conn, %{success: true, data: data})
  end

  def error(conn, status, code, message, details \\ nil) do
    conn
    |> put_status(status)
    |> json(%{
      success: false,
      data: nil,
      error: %{code: code, message: message, details: details}
    })
  end
end
