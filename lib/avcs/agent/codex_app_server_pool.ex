defmodule Avcs.Agent.CodexAppServerPool do
  @moduledoc false

  use GenServer
  require Logger

  @default_max_concurrency 2
  @default_idle_shutdown_after_ms 30 * 60 * 1_000
  @default_idle_check_ms 10_000
  @call_timeout_ms 5_000

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def run_turn(_project, _codex_thread_id, _text, _reference_paths, _on_event, _opts) do
    {:error, "Codex app-server pool requires Avcs thread metadata"}
  end

  def run_turn(
        project,
        avcs_thread_id,
        avcs_turn_id,
        codex_thread_id,
        text,
        reference_paths,
        on_event,
        opts
      ) do
    request = %{
      kind: :run_turn,
      project: project,
      project_id: project["id"],
      avcs_thread_id: avcs_thread_id,
      avcs_turn_id: avcs_turn_id,
      codex_thread_id: clean_string(codex_thread_id),
      text: text,
      reference_paths: reference_paths,
      on_event: on_event,
      opts: opts,
      queued?: false
    }

    GenServer.call(server_name(), {:run_turn, request}, :infinity)
  end

  def list_models do
    GenServer.call(server_name(), :list_models, :infinity)
  end

  def read_thread(codex_thread_id, opts \\ []) do
    timeout = Keyword.get(opts, :timeout_ms, @call_timeout_ms)

    GenServer.call(
      server_name(),
      {:read_thread, clean_string(codex_thread_id), opts},
      timeout + @call_timeout_ms
    )
  end

  def active_turn(project, avcs_thread_id) do
    GenServer.call(
      server_name(),
      {:active_turn, local_key(project, avcs_thread_id)},
      @call_timeout_ms
    )
  end

  def steer_turn(project, avcs_thread_id, text, reference_paths, opts \\ []) do
    case active_turn(project, avcs_thread_id) do
      {:ok, %{worker: worker}} ->
        Avcs.Agent.CodexClient.steer_turn_on(worker, text, reference_paths, opts)

      :none ->
        {:error, :not_running}
    end
  end

  def interrupt_turn(project, avcs_thread_id, avcs_turn_id \\ nil) do
    GenServer.call(
      server_name(),
      {:interrupt_turn, local_key(project, avcs_thread_id), avcs_turn_id},
      @call_timeout_ms
    )
  end

  def respond_approval(_thread_id, turn_id, payload) do
    case GenServer.call(server_name(), {:worker_for_turn, turn_id}, @call_timeout_ms) do
      {:ok, worker} -> Avcs.Agent.CodexClient.respond_approval_on(worker, payload)
      :none -> {:error, :not_running}
    end
  end

  def stats do
    GenServer.call(server_name(), :stats, @call_timeout_ms)
  end

  @impl true
  def init(opts) do
    state = %{
      max_concurrency:
        Keyword.get(
          opts,
          :max_concurrency,
          Application.get_env(:avcs, :codex_pool_max_concurrency, @default_max_concurrency)
        ),
      idle_shutdown_after_ms:
        Keyword.get(
          opts,
          :idle_shutdown_after_ms,
          Application.get_env(
            :avcs,
            :codex_pool_idle_shutdown_after_ms,
            @default_idle_shutdown_after_ms
          )
        ),
      idle_check_ms: Keyword.get(opts, :idle_check_ms, @default_idle_check_ms),
      supervisor: Keyword.get(opts, :supervisor, Avcs.Agent.CodexClientSupervisor),
      worker_module: Keyword.get(opts, :worker_module, Avcs.Agent.CodexClient),
      workers: %{},
      local_routes: %{},
      codex_routes: %{},
      active_by_local: %{},
      active_by_turn: %{},
      waiting: :queue.new()
    }

    schedule_idle_check(state)
    {:ok, state}
  end

  @impl true
  def handle_call({:run_turn, request}, from, state) do
    request =
      request
      |> Map.put(:from, from)
      |> Map.put(:local_key, local_key(request.project, request.avcs_thread_id))

    {:noreply, assign_or_enqueue(request, state)}
  end

  def handle_call(:list_models, from, state) do
    request = %{kind: :list_models, from: from, queued?: false}
    {:noreply, assign_or_enqueue(request, state)}
  end

  def handle_call({:read_thread, codex_thread_id, opts}, from, state) do
    request = %{
      kind: :read_thread,
      from: from,
      codex_thread_id: codex_thread_id,
      opts: opts,
      queued?: false
    }

    {:noreply, assign_or_enqueue(request, state)}
  end

  def handle_call({:active_turn, local_key}, _from, state) do
    case Map.get(state.active_by_local, local_key) do
      nil -> {:reply, :none, state}
      active -> {:reply, {:ok, active}, state}
    end
  end

  def handle_call({:worker_for_turn, turn_id}, _from, state) do
    case Map.get(state.active_by_turn, turn_id) do
      %{worker: worker} -> {:reply, {:ok, worker}, state}
      nil -> {:reply, :none, state}
    end
  end

  def handle_call({:interrupt_turn, local_key, turn_id}, _from, state) do
    case active_or_waiting_turn(state, local_key, turn_id) do
      {:active, active} ->
        result = interrupt_active_worker(state.worker_module, active)
        {:reply, wrap_interrupt_result(result, active.turn_id), state}

      {:waiting, request, waiting} ->
        GenServer.reply(request.from, {:error, :interrupted})
        safe_event(request, {:pool_cancelled, %{reason: :interrupted}})

        {:reply, {:ok, %{turn_id: request.avcs_turn_id, status: "stopping"}},
         %{state | waiting: waiting}}

      :none ->
        {:reply, {:error, :not_running}, state}
    end
  end

  def handle_call(:stats, _from, state) do
    {:reply,
     %{
       worker_count: map_size(state.workers),
       waiting_count: :queue.len(state.waiting),
       local_routes: state.local_routes,
       codex_routes: state.codex_routes,
       active_by_local: state.active_by_local
     }, state}
  end

  @impl true
  def handle_info({:request_finished, worker, request, result}, state) do
    state =
      state
      |> bind_result_codex_thread(worker, request, result)
      |> clear_active_request(worker, request)
      |> mark_worker_idle(worker)
      |> dispatch_waiting()

    {:noreply, state}
  end

  def handle_info({:bind_codex_thread, worker, local_key, codex_thread_id}, state) do
    state =
      if worker_alive?(state, worker) and is_binary(codex_thread_id) and codex_thread_id != "" do
        state
        |> put_codex_route(codex_thread_id, worker)
        |> update_active_codex_thread(local_key, codex_thread_id)
      else
        state
      end

    {:noreply, state}
  end

  def handle_info({:DOWN, _ref, :process, worker, _reason}, state) do
    {:noreply, remove_worker(state, worker) |> dispatch_waiting()}
  end

  def handle_info(:idle_check, state) do
    state =
      state
      |> shutdown_idle_workers()
      |> dispatch_waiting()

    schedule_idle_check(state)
    {:noreply, state}
  end

  defp assign_or_enqueue(request, state) do
    case checkout_worker(request, state) do
      {:ok, worker, state} ->
        assign_request(worker, request, state)

      {:error, reason, state} ->
        GenServer.reply(request.from, {:error, reason})
        state

      :busy ->
        if queueable_request?(request) do
          enqueue_request(request, state)
        else
          GenServer.reply(request.from, {:error, pool_busy_reason(request)})
          state
        end
    end
  end

  defp enqueue_request(request, state) do
    request = %{request | queued?: true}
    safe_event(request, {:pool_queued, %{position: :queue.len(state.waiting) + 1}})
    %{state | waiting: :queue.in(request, state.waiting)}
  end

  defp queueable_request?(%{kind: :run_turn}), do: true
  defp queueable_request?(_request), do: false

  defp pool_busy_reason(%{kind: :list_models}), do: "Codex app-server workers are busy"
  defp pool_busy_reason(%{kind: :read_thread}), do: "Codex app-server workers are busy"
  defp pool_busy_reason(_request), do: "Codex app-server workers are busy"

  defp dispatch_waiting(state) do
    case :queue.out(state.waiting) do
      {{:value, request}, waiting} ->
        state = %{state | waiting: waiting}

        case checkout_worker(request, state) do
          {:ok, worker, state} ->
            worker
            |> assign_request(request, state)
            |> dispatch_waiting()

          {:error, reason, state} ->
            GenServer.reply(request.from, {:error, reason})
            dispatch_waiting(state)

          :busy ->
            %{state | waiting: :queue.in_r(request, state.waiting)}
        end

      {:empty, _waiting} ->
        state
    end
  end

  defp checkout_worker(request, state) do
    case routed_worker(request, state) do
      nil -> checkout_unrouted_worker(state)
      worker -> checkout_routed_worker(worker, state)
    end
  end

  defp checkout_routed_worker(worker, state) do
    cond do
      not worker_alive?(state, worker) ->
        checkout_unrouted_worker(remove_worker(state, worker))

      worker_idle?(state, worker) ->
        {:ok, worker, state}

      true ->
        :busy
    end
  end

  defp checkout_unrouted_worker(state) do
    case idle_worker(state) do
      nil ->
        if map_size(state.workers) < state.max_concurrency do
          start_worker(state)
        else
          :busy
        end

      worker ->
        {:ok, worker, state}
    end
  end

  defp routed_worker(%{local_key: local_key}, state) when not is_nil(local_key) do
    Map.get(state.local_routes, local_key)
  end

  defp routed_worker(%{codex_thread_id: codex_thread_id}, state)
       when is_binary(codex_thread_id) and codex_thread_id != "" do
    Map.get(state.codex_routes, codex_thread_id)
  end

  defp routed_worker(_request, _state), do: nil

  defp start_worker(state) do
    child_spec =
      state.worker_module
      |> apply(:child_spec, [
        [name: nil, id: {:codex_client_worker, System.unique_integer([:positive])}]
      ])
      |> Map.put(:restart, :temporary)

    case DynamicSupervisor.start_child(state.supervisor, child_spec) do
      {:ok, worker} ->
        Process.monitor(worker)

        state =
          put_in(state.workers[worker], %{
            active: nil,
            last_used: now_ms()
          })

        {:ok, worker, state}

      {:error, reason} ->
        {:error, "Codex app-server worker failed to start: #{inspect(reason)}", state}
    end
  end

  defp assign_request(worker, %{kind: :run_turn} = request, state) do
    state =
      state
      |> put_local_route(request.local_key, worker)
      |> maybe_put_codex_route(request.codex_thread_id, worker)
      |> put_worker_active(worker, request)
      |> put_active_route(worker, request)

    start_request_task(worker, request, state)
    state
  end

  defp assign_request(worker, %{kind: :read_thread} = request, state) do
    state =
      state
      |> maybe_put_codex_route(request.codex_thread_id, worker)
      |> put_worker_active(worker, request)

    start_request_task(worker, request, state)
    state
  end

  defp assign_request(worker, request, state) do
    state = put_worker_active(state, worker, request)
    start_request_task(worker, request, state)
    state
  end

  defp start_request_task(worker, request, state) do
    pool = self()
    worker_module = state.worker_module

    Task.start(fn ->
      result = run_worker_request(worker_module, worker, request, pool)
      send(pool, {:request_finished, worker, request, result})
      GenServer.reply(request.from, result)
    end)
  end

  defp run_worker_request(worker_module, worker, %{kind: :run_turn} = request, pool) do
    safe_event(request, {:pool_worker_assigned, %{queued: request.queued?}})

    on_event = wrap_run_event(request, worker, pool)

    worker_module.run_turn_on(
      worker,
      request.project,
      request.codex_thread_id,
      request.text,
      request.reference_paths,
      on_event,
      request.opts
    )
  rescue
    exception ->
      {:error, Exception.message(exception)}
  catch
    :exit, reason -> {:error, "Codex app-server worker exited: #{inspect(reason)}"}
    kind, reason -> {:error, "Codex app-server worker failed: #{inspect({kind, reason})}"}
  end

  defp run_worker_request(worker_module, worker, %{kind: :read_thread} = request, _pool) do
    worker_module.read_thread_on(worker, request.codex_thread_id, request.opts)
  rescue
    exception -> {:error, Exception.message(exception)}
  catch
    :exit, reason -> {:error, "Codex app-server worker exited: #{inspect(reason)}"}
  end

  defp run_worker_request(worker_module, worker, %{kind: :list_models}, _pool) do
    worker_module.list_models_on(worker)
  rescue
    exception -> {:error, Exception.message(exception)}
  catch
    :exit, reason -> {:error, "Codex app-server worker exited: #{inspect(reason)}"}
  end

  defp wrap_run_event(request, worker, pool) do
    fn event ->
      notify_pool_event(event, request, worker, pool)
      safe_event(request, event)
    end
  end

  defp notify_pool_event({:thread_loaded, codex_thread_id, _raw}, request, worker, pool) do
    send(pool, {:bind_codex_thread, worker, request.local_key, codex_thread_id})
  end

  defp notify_pool_event({:turn_started, _turn, raw}, request, worker, pool) do
    codex_thread_id = get_in(raw || %{}, ["params", "threadId"])
    send(pool, {:bind_codex_thread, worker, request.local_key, codex_thread_id})
  end

  defp notify_pool_event(_event, _request, _worker, _pool), do: :ok

  defp put_worker_active(state, worker, request) do
    update_in(state.workers[worker], fn
      nil -> nil
      meta -> %{meta | active: active_request_summary(request)}
    end)
  end

  defp put_active_route(state, worker, request) do
    active = %{
      worker: worker,
      turn_id: request.avcs_turn_id,
      codex_thread_id: request.codex_thread_id
    }

    state
    |> put_in([:active_by_local, request.local_key], active)
    |> put_in([:active_by_turn, request.avcs_turn_id], active)
  end

  defp clear_active_request(state, worker, %{kind: :run_turn} = request) do
    state
    |> update_in([:workers, worker], fn
      nil -> nil
      meta -> %{meta | active: nil}
    end)
    |> update_in([:active_by_local], &Map.delete(&1, request.local_key))
    |> update_in([:active_by_turn], &Map.delete(&1, request.avcs_turn_id))
  end

  defp clear_active_request(state, worker, _request) do
    update_in(state.workers[worker], fn
      nil -> nil
      meta -> %{meta | active: nil}
    end)
  end

  defp mark_worker_idle(state, worker) do
    update_in(state.workers[worker], fn
      nil -> nil
      meta -> %{meta | last_used: now_ms()}
    end)
  end

  defp bind_result_codex_thread(state, worker, %{kind: :run_turn} = request, {:ok, result}) do
    codex_thread_id = Map.get(result, :codex_thread_id) || Map.get(result, "codex_thread_id")

    if is_binary(codex_thread_id) and codex_thread_id != "" do
      state
      |> put_codex_route(codex_thread_id, worker)
      |> update_active_codex_thread(request.local_key, codex_thread_id)
    else
      state
    end
  end

  defp bind_result_codex_thread(state, _worker, _request, _result), do: state

  defp update_active_codex_thread(state, local_key, codex_thread_id) do
    active_by_local =
      Map.update(state.active_by_local, local_key, nil, fn
        nil -> nil
        active -> %{active | codex_thread_id: codex_thread_id}
      end)
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    active_by_turn =
      active_by_local
      |> Map.values()
      |> Map.new(fn active -> {active.turn_id, active} end)

    %{state | active_by_local: active_by_local, active_by_turn: active_by_turn}
  end

  defp active_request_summary(%{kind: :run_turn} = request) do
    %{
      kind: :run_turn,
      local_key: request.local_key,
      turn_id: request.avcs_turn_id,
      codex_thread_id: request.codex_thread_id
    }
  end

  defp active_request_summary(request), do: %{kind: request.kind}

  defp active_or_waiting_turn(state, local_key, turn_id) do
    case active_for_local_turn(state, local_key, turn_id) do
      nil ->
        case pop_waiting_turn(state.waiting, local_key, turn_id) do
          {:ok, request, waiting} -> {:waiting, request, waiting}
          :none -> :none
        end

      active ->
        {:active, active}
    end
  end

  defp active_for_local_turn(state, local_key, turn_id) do
    case Map.get(state.active_by_local, local_key) do
      nil ->
        nil

      %{turn_id: active_turn_id} = active ->
        if blank?(turn_id) or active_turn_id == turn_id, do: active
    end
  end

  defp pop_waiting_turn(waiting, local_key, turn_id) do
    requests = :queue.to_list(waiting)

    case Enum.split_while(requests, fn request ->
           not waiting_turn_matches?(request, local_key, turn_id)
         end) do
      {_before, []} ->
        :none

      {before, [request | after_requests]} ->
        {:ok, request, :queue.from_list(before ++ after_requests)}
    end
  end

  defp waiting_turn_matches?(
         %{kind: :run_turn, local_key: local_key} = request,
         local_key,
         turn_id
       ) do
    blank?(turn_id) or request.avcs_turn_id == turn_id
  end

  defp waiting_turn_matches?(_request, _local_key, _turn_id), do: false

  defp interrupt_active_worker(worker_module, %{worker: worker, turn_id: turn_id}) do
    if module_exports?(worker_module, :interrupt_turn_on, 4) do
      worker_module.interrupt_turn_on(worker, nil, turn_id, [])
    else
      {:error, :interrupt_unsupported}
    end
  end

  defp wrap_interrupt_result({:ok, _result}, turn_id),
    do: {:ok, %{turn_id: turn_id, status: "stopping"}}

  defp wrap_interrupt_result({:error, :interrupted}, turn_id),
    do: {:ok, %{turn_id: turn_id, status: "stopping"}}

  defp wrap_interrupt_result(error, _turn_id), do: error

  defp idle_worker(state) do
    state.workers
    |> Enum.find_value(fn {worker, meta} ->
      if is_nil(meta.active), do: worker
    end)
  end

  defp worker_idle?(state, worker) do
    case Map.get(state.workers, worker) do
      %{active: nil} -> true
      _meta -> false
    end
  end

  defp worker_alive?(state, worker),
    do: Map.has_key?(state.workers, worker) and Process.alive?(worker)

  defp shutdown_idle_workers(state) do
    now = now_ms()

    state.workers
    |> Enum.reduce(state, fn
      {worker, %{active: nil, last_used: last_used}}, acc ->
        if now - last_used >= acc.idle_shutdown_after_ms do
          DynamicSupervisor.terminate_child(acc.supervisor, worker)
          remove_worker(acc, worker)
        else
          acc
        end

      _entry, acc ->
        acc
    end)
  end

  defp remove_worker(state, worker) do
    %{
      state
      | workers: Map.delete(state.workers, worker),
        local_routes: drop_routes_for_worker(state.local_routes, worker),
        codex_routes: drop_routes_for_worker(state.codex_routes, worker),
        active_by_local: drop_routes_for_worker(state.active_by_local, worker),
        active_by_turn: drop_routes_for_worker(state.active_by_turn, worker)
    }
  end

  defp drop_routes_for_worker(routes, worker) do
    routes
    |> Enum.reject(fn
      {_key, %{worker: ^worker}} -> true
      {_key, ^worker} -> true
      _entry -> false
    end)
    |> Map.new()
  end

  defp put_local_route(state, nil, _worker), do: state

  defp put_local_route(state, local_key, worker),
    do: put_in(state.local_routes[local_key], worker)

  defp maybe_put_codex_route(state, nil, _worker), do: state
  defp maybe_put_codex_route(state, "", _worker), do: state

  defp maybe_put_codex_route(state, codex_thread_id, worker),
    do: put_codex_route(state, codex_thread_id, worker)

  defp put_codex_route(state, codex_thread_id, worker),
    do: put_in(state.codex_routes[codex_thread_id], worker)

  defp safe_event(%{on_event: on_event}, event) when is_function(on_event, 1) do
    on_event.(event)
    :ok
  rescue
    exception ->
      Logger.warning("Codex pool event callback failed: #{Exception.message(exception)}")
      :ok
  end

  defp safe_event(_request, _event), do: :ok

  defp schedule_idle_check(%{idle_check_ms: idle_check_ms}) do
    Process.send_after(self(), :idle_check, max(idle_check_ms, 1))
  end

  defp now_ms, do: System.monotonic_time(:millisecond)

  defp local_key(project, avcs_thread_id), do: {project["id"], avcs_thread_id}

  defp blank?(value), do: is_nil(value) or value == ""

  defp clean_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      string -> string
    end
  end

  defp clean_string(_value), do: nil

  defp server_name do
    Application.get_env(:avcs, :codex_app_server_pool_server, __MODULE__)
  end

  defp module_exports?(module, function, arity) when is_atom(module) do
    Code.ensure_loaded?(module) and function_exported?(module, function, arity)
  end

  defp module_exports?(_module, _function, _arity), do: false
end
