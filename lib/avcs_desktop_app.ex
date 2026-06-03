if Mix.target() == :app do
  defmodule AvcsDesktopApp do
    @moduledoc false

    use GenServer

    require Logger

    def start_link(arg) do
      GenServer.start_link(__MODULE__, arg, name: __MODULE__)
    end

    @impl true
    def init(_) do
      ref = Process.monitor(ElixirKit.PubSub)

      ElixirKit.PubSub.subscribe("messages")
      ElixirKit.PubSub.broadcast("messages", "ready:" <> Avcs.Desktop.default_url())

      {:ok, %{ref: ref, log_path: System.get_env("LOG_PATH")}}
    end

    @impl true
    def handle_info("open:/logs", %{log_path: nil} = state) do
      Logger.warning("LOG_PATH is not set")
      {:noreply, state}
    end

    def handle_info("open:/logs", state) do
      Avcs.Desktop.open_file(state.log_path)
      {:noreply, state}
    end

    def handle_info("open:" <> url, state) do
      url
      |> Avcs.Desktop.expand_desktop_url()
      |> Avcs.Desktop.browser_open()

      {:noreply, state}
    end

    def handle_info({:DOWN, ref, :process, _pid, reason}, state) when ref == state.ref do
      Logger.info("desktop bridge stopped: #{inspect(reason)}")
      System.stop(0)
      {:noreply, state}
    end
  end
end
