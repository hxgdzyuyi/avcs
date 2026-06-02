defmodule AvcsWeb.HealthControllerTest do
  use AvcsWeb.ConnCase, async: true

  test "GET /api/health returns an ok envelope", %{conn: conn} do
    conn = get(conn, ~p"/api/health")

    assert json_response(conn, 200) == %{
             "success" => true,
             "data" => %{"status" => "ok"}
           }
  end
end
