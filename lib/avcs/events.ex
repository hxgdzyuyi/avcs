defmodule Avcs.Events do
  @moduledoc false

  def broadcast(event, payload) do
    AvcsWeb.Endpoint.broadcast("avcs:lobby", event, payload)
  end
end
