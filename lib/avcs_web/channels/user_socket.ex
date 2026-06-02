defmodule AvcsWeb.UserSocket do
  use Phoenix.Socket

  channel "avcs:lobby", AvcsWeb.AvcsChannel

  @impl true
  def connect(_params, socket, _connect_info), do: {:ok, socket}

  @impl true
  def id(_socket), do: nil
end
