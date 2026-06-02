defmodule AvcsWeb.PageController do
  use AvcsWeb, :controller

  def home(conn, _params) do
    redirect(conn, to: ~p"/web/")
  end
end
