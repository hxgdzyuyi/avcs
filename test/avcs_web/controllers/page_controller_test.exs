defmodule AvcsWeb.PageControllerTest do
  use AvcsWeb.ConnCase

  test "GET /", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert redirected_to(conn, 302) == ~p"/web/"
  end
end
