defmodule Avcs.Session do
  @moduledoc false

  use GenServer

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def current_project do
    GenServer.call(__MODULE__, :current_project)
  end

  def set_current_project(project) do
    GenServer.call(__MODULE__, {:set_current_project, project})
  end

  def current_thread_id do
    GenServer.call(__MODULE__, :current_thread_id)
  end

  def set_current_thread_id(thread_id) do
    GenServer.call(__MODULE__, {:set_current_thread_id, thread_id})
  end

  @impl true
  def init(_opts), do: {:ok, %{project: nil, current_thread_id: nil}}

  @impl true
  def handle_call(:current_project, _from, state) do
    {:reply, enrich_project(state), state}
  end

  def handle_call({:set_current_project, nil}, _from, state) do
    {:reply, :ok, %{state | project: nil, current_thread_id: nil}}
  end

  def handle_call({:set_current_project, project}, _from, state) do
    thread_id = project["current_thread_id"] || project[:current_thread_id]
    next = %{state | project: project, current_thread_id: thread_id}
    {:reply, :ok, next}
  end

  def handle_call(:current_thread_id, _from, state) do
    {:reply, state.current_thread_id, state}
  end

  def handle_call({:set_current_thread_id, thread_id}, _from, state) do
    project =
      case state.project do
        nil -> nil
        project -> Map.put(project, "current_thread_id", thread_id)
      end

    {:reply, :ok, %{state | project: project, current_thread_id: thread_id}}
  end

  defp enrich_project(%{project: nil}), do: nil

  defp enrich_project(%{project: project, current_thread_id: thread_id}) do
    Map.put(project, "current_thread_id", thread_id)
  end
end
