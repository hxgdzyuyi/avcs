defmodule Avcs.Agent.CodexAppServerPoolTest do
  use ExUnit.Case, async: false

  defmodule FakeWorker do
    use GenServer

    def child_spec(opts) do
      %{
        id: Keyword.get(opts, :id, __MODULE__),
        start: {__MODULE__, :start_link, [opts]},
        restart: :temporary,
        type: :worker
      }
    end

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    def run_turn_on(worker, project, codex_thread_id, text, reference_paths, on_event, opts) do
      GenServer.call(
        worker,
        {:run_turn, project, codex_thread_id, text, reference_paths, on_event, opts},
        :infinity
      )
    end

    def read_thread_on(worker, codex_thread_id, opts) do
      GenServer.call(worker, {:read_thread, codex_thread_id, opts})
    end

    def list_models_on(worker), do: GenServer.call(worker, :list_models)

    def steer_turn_on(worker, text, reference_paths, _opts) do
      GenServer.call(worker, {:steer_turn, text, reference_paths})
    end

    def interrupt_turn_on(worker, _thread_id, turn_id, _opts) do
      GenServer.call(worker, {:interrupt_turn, turn_id})
    end

    @impl true
    def init(_opts) do
      test_pid = Application.fetch_env!(:avcs, :codex_pool_test_pid)
      send(test_pid, {:worker_started, self()})
      {:ok, %{test_pid: test_pid, active_from: nil, active_on_event: nil}}
    end

    @impl true
    def handle_call(
          {:run_turn, _project, codex_thread_id, text, _reference_paths, on_event, _opts},
          from,
          state
        ) do
      send(state.test_pid, {:run_turn, self(), codex_thread_id, text})
      {:noreply, %{state | active_from: from, active_on_event: on_event}}
    end

    def handle_call({:read_thread, codex_thread_id, _opts}, _from, state) do
      send(state.test_pid, {:read_thread, self(), codex_thread_id})
      {:reply, {:ok, %{"id" => codex_thread_id}}, state}
    end

    def handle_call(:list_models, _from, state) do
      send(state.test_pid, {:list_models, self()})
      {:reply, {:ok, [%{"id" => "fake"}]}, state}
    end

    def handle_call({:steer_turn, text, reference_paths}, _from, state) do
      send(state.test_pid, {:steer_turn, self(), text, reference_paths})
      {:reply, {:ok, %{"turnId" => "codex-turn-active"}}, state}
    end

    def handle_call({:steer_turn, text, reference_paths, _timeout_ms}, _from, state) do
      send(state.test_pid, {:steer_turn, self(), text, reference_paths})
      {:reply, {:ok, %{"turnId" => "codex-turn-active"}}, state}
    end

    def handle_call({:interrupt_turn, turn_id}, _from, state) do
      send(state.test_pid, {:interrupt_turn, self(), turn_id})
      {:reply, {:ok, %{}}, state}
    end

    @impl true
    def handle_info({:complete, codex_thread_id}, %{active_from: from} = state)
        when not is_nil(from) do
      state.active_on_event.({:thread_loaded, codex_thread_id, %{}})
      GenServer.reply(from, {:ok, result(codex_thread_id)})
      {:noreply, %{state | active_from: nil, active_on_event: nil}}
    end

    defp result(codex_thread_id) do
      %{
        codex_thread_id: codex_thread_id,
        codex_turn_id: "codex-turn-active",
        assistant_text: "done",
        items: [],
        thread_name: "Fake"
      }
    end
  end

  setup do
    previous_pool_server = Application.get_env(:avcs, :codex_app_server_pool_server)
    previous_test_pid = Application.get_env(:avcs, :codex_pool_test_pid)
    Application.put_env(:avcs, :codex_pool_test_pid, self())

    supervisor_name = :"codex_pool_test_supervisor_#{System.unique_integer([:positive])}"
    pool_name = :"codex_pool_test_#{System.unique_integer([:positive])}"

    start_supervised!({DynamicSupervisor, strategy: :one_for_one, name: supervisor_name})

    pool =
      start_supervised!(
        {Avcs.Agent.CodexAppServerPool,
         name: pool_name,
         supervisor: supervisor_name,
         worker_module: FakeWorker,
         max_concurrency: 2,
         idle_shutdown_after_ms: 60_000,
         idle_check_ms: 60_000}
      )

    Application.put_env(:avcs, :codex_app_server_pool_server, pool_name)

    on_exit(fn ->
      restore_env(:codex_app_server_pool_server, previous_pool_server)
      restore_env(:codex_pool_test_pid, previous_test_pid)
    end)

    %{pool: pool}
  end

  test "queues requests beyond max_concurrency and dispatches FIFO" do
    project = project("project-queue")

    first = async_run(project, "thread-1", "turn-1", nil, "one")
    second = async_run(project, "thread-2", "turn-2", nil, "two")
    third = async_run(project, "thread-3", "turn-3", nil, "three")

    assert_receive {:worker_started, worker_1}
    assert_receive {:run_turn, ^worker_1, nil, "one"}
    assert_receive {:worker_started, worker_2}
    assert_receive {:run_turn, ^worker_2, nil, "two"}
    refute_received {:run_turn, _worker, _codex_thread_id, "three"}

    assert %{worker_count: 2, waiting_count: 1} = Avcs.Agent.CodexAppServerPool.stats()

    send(worker_1, {:complete, "codex-thread-1"})
    assert {:ok, %{codex_thread_id: "codex-thread-1"}} = Task.await(first, 1_000)
    assert_receive {:run_turn, ^worker_1, nil, "three"}

    send(worker_2, {:complete, "codex-thread-2"})
    send(worker_1, {:complete, "codex-thread-3"})
    assert {:ok, %{codex_thread_id: "codex-thread-2"}} = Task.await(second, 1_000)
    assert {:ok, %{codex_thread_id: "codex-thread-3"}} = Task.await(third, 1_000)
  end

  test "reuses local and codex routes for the same worker" do
    project = project("project-routes")

    first = async_run(project, "thread-1", "turn-1", nil, "first")
    assert_receive {:worker_started, worker}
    assert_receive {:run_turn, ^worker, nil, "first"}
    send(worker, {:complete, "codex-thread-routed"})
    assert {:ok, %{codex_thread_id: "codex-thread-routed"}} = Task.await(first, 1_000)

    second = async_run(project, "thread-1", "turn-2", "codex-thread-routed", "second")
    assert_receive {:run_turn, ^worker, "codex-thread-routed", "second"}
    send(worker, {:complete, "codex-thread-routed"})
    assert {:ok, %{codex_thread_id: "codex-thread-routed"}} = Task.await(second, 1_000)

    assert {:ok, %{"id" => "codex-thread-routed"}} =
             Avcs.Agent.CodexAppServerPool.read_thread("codex-thread-routed")

    assert_receive {:read_thread, ^worker, "codex-thread-routed"}
  end

  test "idle shutdown removes workers and routes" do
    previous_pool_server = Application.get_env(:avcs, :codex_app_server_pool_server)
    supervisor_name = :"codex_pool_idle_supervisor_#{System.unique_integer([:positive])}"
    pool_name = :"codex_pool_idle_#{System.unique_integer([:positive])}"

    start_supervised!({DynamicSupervisor, strategy: :one_for_one, name: supervisor_name})

    start_supervised!(%{
      id: pool_name,
      start:
        {Avcs.Agent.CodexAppServerPool, :start_link,
         [
           [
             name: pool_name,
             supervisor: supervisor_name,
             worker_module: FakeWorker,
             max_concurrency: 2,
             idle_shutdown_after_ms: 5,
             idle_check_ms: 5
           ]
         ]},
      type: :worker
    })

    Application.put_env(:avcs, :codex_app_server_pool_server, pool_name)

    project = project("project-idle")
    task = async_run(project, "thread-1", "turn-1", nil, "idle")
    assert_receive {:worker_started, worker}
    assert_receive {:run_turn, ^worker, nil, "idle"}
    send(worker, {:complete, "codex-thread-idle"})
    assert {:ok, %{codex_thread_id: "codex-thread-idle"}} = Task.await(task, 1_000)

    wait_until(fn -> Avcs.Agent.CodexAppServerPool.stats().worker_count == 0 end)
    assert %{local_routes: %{}, codex_routes: %{}} = Avcs.Agent.CodexAppServerPool.stats()

    Application.put_env(:avcs, :codex_app_server_pool_server, previous_pool_server)
  end

  test "active same-thread input steers without starting another worker" do
    project = project("project-steer")
    task = async_run(project, "thread-1", "turn-1", nil, "active")

    assert_receive {:worker_started, worker}
    assert_receive {:run_turn, ^worker, nil, "active"}

    assert {:ok, %{turn_id: "turn-1", worker: ^worker}} =
             Avcs.Agent.CodexAppServerPool.active_turn(project, "thread-1")

    assert {:ok, %{"turnId" => "codex-turn-active"}} =
             Avcs.Agent.CodexAppServerPool.steer_turn(project, "thread-1", "steer", [])

    assert_receive {:steer_turn, ^worker, "steer", []}
    refute_received {:worker_started, _other_worker}

    send(worker, {:complete, "codex-thread-steer"})
    assert {:ok, %{codex_thread_id: "codex-thread-steer"}} = Task.await(task, 1_000)
  end

  test "interrupt_turn forwards to the active worker" do
    project = project("project-interrupt-active")
    task = async_run(project, "thread-1", "turn-1", nil, "active")

    assert_receive {:worker_started, worker}
    assert_receive {:run_turn, ^worker, nil, "active"}

    assert {:ok, %{turn_id: "turn-1", status: "stopping"}} =
             Avcs.Agent.CodexAppServerPool.interrupt_turn(project, "thread-1", "turn-1")

    assert_receive {:interrupt_turn, ^worker, "turn-1"}

    send(worker, {:complete, "codex-thread-interrupt"})
    assert {:ok, %{codex_thread_id: "codex-thread-interrupt"}} = Task.await(task, 1_000)
  end

  test "interrupt_turn cancels a queued request before worker assignment" do
    project = project("project-interrupt-queued")

    first = async_run(project, "thread-1", "turn-1", nil, "one")
    second = async_run(project, "thread-2", "turn-2", nil, "two")
    third = async_run(project, "thread-3", "turn-3", nil, "three")

    assert_receive {:worker_started, worker_1}
    assert_receive {:run_turn, ^worker_1, nil, "one"}
    assert_receive {:worker_started, worker_2}
    assert_receive {:run_turn, ^worker_2, nil, "two"}

    assert {:ok, %{turn_id: "turn-3", status: "stopping"}} =
             Avcs.Agent.CodexAppServerPool.interrupt_turn(project, "thread-3", "turn-3")

    assert {:error, :interrupted} = Task.await(third, 1_000)
    refute_received {:run_turn, _worker, nil, "three"}
    assert %{waiting_count: 0} = Avcs.Agent.CodexAppServerPool.stats()

    send(worker_1, {:complete, "codex-thread-1"})
    send(worker_2, {:complete, "codex-thread-2"})
    assert {:ok, %{codex_thread_id: "codex-thread-1"}} = Task.await(first, 1_000)
    assert {:ok, %{codex_thread_id: "codex-thread-2"}} = Task.await(second, 1_000)
  end

  defp async_run(project, thread_id, turn_id, codex_thread_id, text) do
    Task.async(fn ->
      Avcs.Agent.CodexAppServerPool.run_turn(
        project,
        thread_id,
        turn_id,
        codex_thread_id,
        text,
        [],
        fn _event -> :ok end,
        %{}
      )
    end)
  end

  defp project(id), do: %{"id" => id}

  defp wait_until(fun) do
    deadline = System.monotonic_time(:millisecond) + 1_000
    do_wait_until(fun, deadline)
  end

  defp do_wait_until(fun, deadline) do
    if fun.() do
      :ok
    else
      if System.monotonic_time(:millisecond) > deadline do
        flunk("condition was not met before timeout")
      else
        Process.sleep(10)
        do_wait_until(fun, deadline)
      end
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:avcs, key)
  defp restore_env(key, value), do: Application.put_env(:avcs, key, value)
end
