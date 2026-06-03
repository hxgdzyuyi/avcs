defmodule Avcs.Agent.CodexClient do
  @moduledoc false

  use GenServer
  require Logger

  @default_request_timeout_ms 30_000
  @default_idle_timeout_ms 1_800_000
  @thread_read_timeout_ms 5_000
  @model_list_timeout_ms 8_000
  @call_timeout_buffer_ms 10_000
  @shutdown_timeout_ms 5_000
  @os_process_term_wait_ms 1_000
  @os_process_kill_wait_ms 500
  @os_process_poll_ms 50
  @stdout_buffer_max_bytes 32 * 1024 * 1024

  def start_link(opts \\ []) do
    case Keyword.fetch(opts, :name) do
      {:ok, nil} -> GenServer.start_link(__MODULE__, opts)
      {:ok, name} -> GenServer.start_link(__MODULE__, opts, name: name)
      :error -> GenServer.start_link(__MODULE__, opts, name: __MODULE__)
    end
  end

  @doc false
  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :id, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      shutdown: @shutdown_timeout_ms,
      type: :worker
    }
  end

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)

    {:ok,
     %{
       port: nil,
       os_pid: nil,
       initialized?: false,
       loaded_thread_ids: MapSet.new(),
       active: nil,
       stdout_buffer: "",
       request_id: 1,
       last_used: System.monotonic_time(:millisecond)
     }}
  end

  def run_turn(project, codex_thread_id, text, reference_paths) do
    run_turn(project, codex_thread_id, text, reference_paths, fn _event -> :ok end, %{})
  end

  def run_turn(project, codex_thread_id, text, reference_paths, on_event) do
    run_turn(project, codex_thread_id, text, reference_paths, on_event, %{})
  end

  def run_turn(project, codex_thread_id, text, reference_paths, on_event, opts) do
    call_server(
      {:run_turn, project, codex_thread_id, text, reference_paths, on_event, opts},
      :infinity
    )
  end

  def run_turn_on(server, project, codex_thread_id, text, reference_paths, on_event, opts) do
    call_server(
      server,
      {:run_turn, project, codex_thread_id, text, reference_paths, on_event, opts},
      :infinity
    )
  end

  def list_models do
    timeout = Application.get_env(:avcs, :codex_model_list_timeout_ms, @model_list_timeout_ms)
    call_server(:list_models, timeout + @call_timeout_buffer_ms)
  end

  def list_models_on(server) do
    timeout = Application.get_env(:avcs, :codex_model_list_timeout_ms, @model_list_timeout_ms)
    call_server(server, :list_models, timeout + @call_timeout_buffer_ms)
  end

  def read_thread(codex_thread_id, opts \\ []) do
    timeout = Keyword.get(opts, :timeout_ms, codex_request_timeout_ms())

    call_server(
      {:read_thread, codex_thread_id, Keyword.get(opts, :include_turns, false), timeout},
      timeout + @call_timeout_buffer_ms
    )
  end

  def read_thread_on(server, codex_thread_id, opts \\ []) do
    timeout = Keyword.get(opts, :timeout_ms, codex_request_timeout_ms())

    call_server(
      server,
      {:read_thread, codex_thread_id, Keyword.get(opts, :include_turns, false), timeout},
      timeout + @call_timeout_buffer_ms
    )
  end

  def steer_turn_on(server, text, reference_paths, opts \\ []) do
    timeout = Keyword.get(opts, :timeout_ms, codex_request_timeout_ms())

    call_server(
      server,
      {:steer_turn, text, reference_paths, timeout},
      timeout + @call_timeout_buffer_ms
    )
  end

  def interrupt_turn(_project, _thread_id, _turn_id, opts \\ []) do
    timeout = Keyword.get(opts, :timeout_ms, codex_request_timeout_ms())

    call_server(
      {:interrupt_turn, timeout},
      timeout + @call_timeout_buffer_ms
    )
  end

  def interrupt_turn_on(server, _thread_id, _turn_id, opts \\ []) do
    timeout = Keyword.get(opts, :timeout_ms, codex_request_timeout_ms())

    call_server(
      server,
      {:interrupt_turn, timeout},
      timeout + @call_timeout_buffer_ms
    )
  end

  def respond_approval(_thread_id, _turn_id, payload) do
    case resolve_server() do
      nil ->
        {:error, :not_running}

      server ->
        send(server, {:approval_response, payload})
        :ok
    end
  end

  def respond_approval_on(server, payload) do
    if is_pid(server) and Process.alive?(server) do
      send(server, {:approval_response, payload})
      :ok
    else
      {:error, :not_running}
    end
  end

  @impl true
  def handle_call(
        {:run_turn, project, codex_thread_id, text, reference_paths, on_event, opts},
        from,
        state
      ) do
    request = %{
      kind: :run_turn,
      from: from,
      project: project,
      codex_thread_id: codex_thread_id,
      text: text,
      reference_paths: reference_paths,
      on_event: on_event,
      opts: normalize_turn_opts(opts),
      request_timeout_ms: codex_request_timeout_ms(),
      idle_timeout_ms: codex_idle_timeout_ms()
    }

    {:noreply, begin_request(request, state)}
  end

  @impl true
  def handle_call(:list_models, from, state) do
    timeout = Application.get_env(:avcs, :codex_model_list_timeout_ms, @model_list_timeout_ms)

    request = %{
      kind: :list_models,
      from: from,
      on_event: fn _event -> :ok end,
      timeout_ms: timeout
    }

    {:noreply, begin_request(request, state)}
  end

  def handle_call({:read_thread, codex_thread_id, include_turns, timeout_ms}, from, state) do
    request = %{
      kind: :read_thread,
      from: from,
      codex_thread_id: codex_thread_id,
      include_turns: include_turns == true,
      on_event: fn _event -> :ok end,
      timeout_ms: timeout_ms
    }

    {:noreply, begin_request(request, state)}
  end

  def handle_call({:steer_turn, text, reference_paths, timeout_ms}, from, state) do
    request = %{
      from: from,
      text: text,
      reference_paths: reference_paths,
      timeout_ms: timeout_ms
    }

    {:noreply, begin_steer_request(request, state)}
  end

  def handle_call({:interrupt_turn, timeout_ms}, from, state) do
    request = %{
      from: from,
      timeout_ms: timeout_ms
    }

    {:noreply, begin_interrupt_request(request, state)}
  end

  @impl true
  def handle_call(:last_used, _from, state) do
    {:reply, state.last_used, state}
  end

  @impl true
  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.warning(
      "Codex app-server exited with status #{status}, os_pid: #{inspect(state.os_pid)}"
    )

    cleanup_os_process(state.os_pid)

    state =
      state
      |> fail_active("Codex app-server exited with status #{status}", close_port?: false)
      |> clear_port()

    {:noreply, state}
  end

  @impl true
  def handle_info({:EXIT, port, reason}, %{port: port} = state) do
    Logger.warning(
      "Codex app-server port exited: #{inspect(reason)}, os_pid: #{inspect(state.os_pid)}"
    )

    cleanup_os_process(state.os_pid)

    state =
      state
      |> fail_active("Codex app-server port exited: #{inspect(reason)}", close_port?: false)
      |> clear_port()

    {:noreply, state}
  end

  @impl true
  def handle_info({port, {:data, {:eol, line}}}, %{port: port} = state) do
    line = buffered_line(state, line)

    state =
      state
      |> Map.put(:stdout_buffer, "")
      |> touch()

    state =
      case decode_line(line) do
        {:ok, message} ->
          handle_app_server_message(message, state)

        {:error, reason} ->
          Logger.debug(
            "Ignoring undecodable Codex app-server line: #{decode_error_summary(reason, line)}"
          )

          state
      end

    {:noreply, state}
  end

  @impl true
  def handle_info({port, {:data, {:noeol, line}}}, %{port: port} = state) do
    state = append_stdout_buffer(state, line)

    {:noreply, state}
  end

  @impl true
  def handle_info({:approval_response, payload}, state) do
    {:noreply, handle_approval_response(payload, state)}
  end

  @impl true
  def handle_info({:operation_timeout, timer_ref}, state) do
    state =
      case state.active do
        %{timer_ref: ^timer_ref, kind: :run_turn, phase: :refresh_thread_name} = active ->
          finish_request({:ok, run_result(active)}, state)

        %{timer_ref: ^timer_ref, timer_kind: :idle} ->
          fail_active(state, "Codex app-server idle timed out", close_port?: true)

        %{timer_ref: ^timer_ref} ->
          fail_active(state, "Codex app-server timed out", close_port?: true)

        _active ->
          state
      end

    {:noreply, state}
  end

  @impl true
  def handle_info({port, _message}, %{port: port} = state) do
    {:noreply, touch(state)}
  end

  @impl true
  def handle_info(_message, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    state = finish_request({:error, "Codex app-server stopped"}, state)
    close_port(state.port)
    cleanup_os_process(state.os_pid)
    :ok
  end

  defp begin_request(request, %{active: nil} = state) do
    state =
      state
      |> ensure_runtime_state()
      |> touch()

    cond do
      state.port && port_alive?(state.port) && state.initialized? ->
        start_request(request, state)

      state.port && port_alive?(state.port) ->
        start_initialize(request, state)

      true ->
        state
        |> clear_port()
        |> start_port_for_request(request)
    end
  end

  defp begin_request(request, state) do
    GenServer.reply(request.from, {:error, "Codex app-server is busy"})
    state
  end

  defp begin_steer_request(
         request,
         %{active: %{kind: :run_turn, thread_id: thread_id} = active, port: port} = state
       )
       when is_binary(thread_id) and is_port(port) do
    active = ensure_active_steer_state(active)

    if codex_turn_id(active) do
      send_turn_steer(request, active, state)
    else
      put_active(state, %{active | pending_steers: active.pending_steers ++ [request]})
    end
  end

  defp begin_steer_request(request, state) do
    GenServer.reply(request.from, {:error, "Codex turn is not active"})
    state
  end

  defp begin_interrupt_request(
         request,
         %{active: %{kind: :run_turn, thread_id: thread_id} = active, port: port} = state
       )
       when is_binary(thread_id) and is_port(port) do
    active = ensure_active_interrupt_state(active)

    if codex_turn_id(active) do
      send_turn_interrupt(request, active, state)
    else
      put_active(state, %{active | pending_interrupts: active.pending_interrupts ++ [request]})
    end
  end

  defp begin_interrupt_request(request, state) do
    GenServer.reply(request.from, {:error, "Codex turn is not active"})
    state
  end

  defp start_port_for_request(state, request) do
    with {:ok, codex} <- codex_executable(),
         {:ok, port, os_pid} <- start_port(codex) do
      Logger.debug("Codex app-server started with os_pid #{inspect(os_pid)}")

      state = Map.merge(state, %{port: port, os_pid: os_pid, initialized?: false})
      start_initialize(request, state)
    else
      {:error, reason} ->
        GenServer.reply(request.from, {:error, reason})
        state
    end
  end

  defp start_initialize(request, state) do
    send_json(state.port, %{
      method: "initialize",
      id: 0,
      params: %{
        clientInfo: %{name: "avcs", title: "Avcs", version: "0.1.0"},
        capabilities: %{experimentalApi: true}
      }
    })

    send_json(state.port, %{method: "initialized", params: %{}})

    active = %{
      kind: :initialize,
      from: request.from,
      on_event: request.on_event,
      request: request,
      request_id: 0,
      timer_ref: schedule_timeout(request_timeout_ms(request)),
      timer_kind: :request
    }

    %{state | active: active}
  end

  defp start_request(%{kind: :list_models} = request, state) do
    params = %{limit: 100, includeHidden: false}
    validate_params(:model_list_params, params, "model/list params")

    {id, state} = next_request_id(state)

    send_json(state.port, %{
      method: "model/list",
      id: id,
      params: params
    })

    active = %{
      kind: :list_models,
      from: request.from,
      request_id: id,
      timer_ref: schedule_timeout(request.timeout_ms),
      timer_kind: :request
    }

    %{state | active: active}
  end

  defp start_request(%{kind: :read_thread} = request, state) do
    params = %{threadId: request.codex_thread_id, includeTurns: request.include_turns}
    validate_params(:thread_read_params, params, "thread/read params")

    {id, state} = next_request_id(state)

    send_json(state.port, %{
      method: "thread/read",
      id: id,
      params: params
    })

    active = %{
      kind: :read_thread,
      from: request.from,
      request_id: id,
      timer_ref: schedule_timeout(request.timeout_ms),
      timer_kind: :request
    }

    %{state | active: active}
  end

  defp start_request(%{kind: :run_turn, codex_thread_id: thread_id} = request, state)
       when is_binary(thread_id) and thread_id != "" do
    if thread_loaded?(state, thread_id) do
      request
      |> new_run_active(thread_id)
      |> send_turn_start(state)
    else
      send_thread_request(request, state)
    end
  end

  defp start_request(%{kind: :run_turn} = request, state) do
    send_thread_request(request, state)
  end

  defp handle_app_server_message(%{"id" => id, "error" => error} = message, state) do
    handle_response_error(id, error, message, state)
  end

  defp handle_app_server_message(%{"id" => id, "result" => result} = message, state) do
    handle_response_result(id, result, message, state)
  end

  defp handle_app_server_message(%{"method" => _method} = message, state) do
    handle_notification(message, state)
  end

  defp handle_app_server_message(message, state) do
    Logger.debug("Ignoring Codex app-server message: #{inspect(message)}")
    state
  end

  defp handle_response_error(0, error, _message, %{active: %{kind: :initialize}} = state) do
    fail_active(state, error_message(error), close_port?: true)
  end

  defp handle_response_error(
         id,
         error,
         message,
         %{active: %{kind: :list_models, request_id: id}} = state
       ) do
    validate_notification(message)
    finish_request({:error, error_message(error)}, state)
  end

  defp handle_response_error(
         id,
         error,
         message,
         %{active: %{kind: :read_thread, request_id: id}} = state
       ) do
    validate_notification(message)
    finish_request({:error, error_message(error)}, state)
  end

  defp handle_response_error(id, error, message, %{active: %{kind: :run_turn} = active} = state) do
    cond do
      active[:thread_request_id] == id ->
        validate_notification(message)
        finish_request({:error, error_message(error)}, state)

      active[:turn_request_id] == id ->
        validate_notification(message)
        finish_request({:error, error_message(error)}, state)

      active[:refresh_request_id] == id ->
        finish_request({:ok, run_result(active)}, state)

      steer = steer_request(active, id) ->
        validate_notification(message)
        GenServer.reply(steer.from, {:error, error_message(error)})
        active.on_event.({:steer_error, id, error, message})

        state
        |> put_active(delete_steer_request(active, id))
        |> reset_idle_timer()

      interrupt = interrupt_request(active, id) ->
        validate_notification(message)
        GenServer.reply(interrupt.from, {:error, error_message(error)})
        active.on_event.({:interrupt_error, id, error, message})

        state
        |> put_active(delete_interrupt_request(active, id))
        |> reset_idle_timer()

      MapSet.member?(active.approval_request_ids, id) ->
        active.on_event.({:response_error, id, error, message})

        state
        |> put_active(%{
          active
          | approval_request_ids: MapSet.delete(active.approval_request_ids, id)
        })
        |> reset_idle_timer()

      true ->
        active.on_event.({:response_error, id, error, message})
        reset_idle_timer(state)
    end
  end

  defp handle_response_error(id, error, message, state) do
    Logger.debug(
      "Ignoring idle Codex app-server error response #{inspect(id)}: #{inspect(error)}"
    )

    validate_notification(message)
    state
  end

  defp handle_response_result(
         0,
         _result,
         _message,
         %{active: %{kind: :initialize} = active} = state
       ) do
    request = active.request

    state =
      state
      |> cancel_active_timer()
      |> Map.merge(%{active: nil, initialized?: true})

    start_request(request, state)
  end

  defp handle_response_result(
         id,
         _result,
         message,
         %{active: %{kind: :list_models, request_id: id}} = state
       ) do
    validate_result(:model_list_response, message, "model/list response")
    finish_request({:ok, get_in(message, ["result", "data"]) || []}, state)
  end

  defp handle_response_result(
         id,
         _result,
         message,
         %{active: %{kind: :read_thread, request_id: id}} = state
       ) do
    validate_result(:thread_read_response, message, "thread/read response")
    thread = get_in(message, ["result", "thread"]) || %{}
    finish_request({:ok, compact_thread(thread)}, state)
  end

  defp handle_response_result(id, result, message, %{active: %{kind: :run_turn} = active} = state) do
    cond do
      active[:thread_request_id] == id ->
        handle_thread_response(result, message, active, state)

      active[:turn_request_id] == id ->
        handle_turn_start_response(result, active, state)

      active[:refresh_request_id] == id ->
        validate_result(:thread_read_response, message, "thread/read response")
        active = %{active | acc: put_thread_name(active.acc, thread_name_from_response(message))}
        finish_request({:ok, run_result(active)}, put_active(state, active))

      steer = steer_request(active, id) ->
        validate_result(:turn_steer_response, %{"result" => result}, "turn/steer response")
        GenServer.reply(steer.from, {:ok, result})
        active.on_event.({:steer_response, id, result, message})

        state
        |> put_active(delete_steer_request(active, id))
        |> reset_idle_timer()

      interrupt = interrupt_request(active, id) ->
        validate_result(
          :turn_interrupt_response,
          %{"result" => result},
          "turn/interrupt response"
        )

        GenServer.reply(interrupt.from, {:ok, result})
        active.on_event.({:interrupt_response, id, result, message})

        state
        |> put_active(delete_interrupt_request(active, id))
        |> reset_idle_timer()

      MapSet.member?(active.approval_request_ids, id) ->
        validate_result(
          :thread_approve_guardian_denied_action_response,
          %{"result" => result},
          "thread/approveGuardianDeniedAction response"
        )

        active.on_event.({:response, id, result, message})

        state
        |> put_active(%{
          active
          | approval_request_ids: MapSet.delete(active.approval_request_ids, id)
        })
        |> reset_idle_timer()

      true ->
        active.on_event.({:response, id, result, message})
        reset_idle_timer(state)
    end
  end

  defp handle_response_result(id, _result, message, state) do
    Logger.debug("Ignoring idle Codex app-server response: #{inspect(id)}")
    validate_notification(message)
    state
  end

  defp handle_notification(message, %{active: %{kind: :initialize, on_event: on_event}} = state) do
    validate_notification(message)
    forward_notification_event(message, on_event)
    state
  end

  defp handle_notification(message, %{active: %{kind: :run_turn} = active} = state) do
    message
    |> handle_turn_notification(active, state)
    |> reset_idle_timer()
  end

  defp handle_notification(message, state) do
    validate_notification(message)
    Logger.debug("Ignoring idle Codex app-server notification: #{message["method"]}")
    state
  end

  defp handle_turn_notification(
         %{"method" => "item/autoApprovalReview/started", "params" => params} = message,
         active,
         state
       ) do
    validate_params(
      :item_auto_approval_review_started_notification,
      params,
      "item/autoApprovalReview/started notification"
    )

    active.on_event.({:approval_review_started, params, message})
    state
  end

  defp handle_turn_notification(
         %{"method" => "item/autoApprovalReview/completed", "params" => params} = message,
         active,
         state
       ) do
    validate_params(
      :item_auto_approval_review_completed_notification,
      params,
      "item/autoApprovalReview/completed notification"
    )

    active.on_event.({:approval_review_completed, params, message})
    state
  end

  defp handle_turn_notification(
         %{"method" => "turn/started", "params" => %{"turn" => turn}} = message,
         active,
         state
       ) do
    validate_notification(message)
    active.on_event.({:turn_started, turn, message})

    active =
      active
      |> put_codex_turn_id(turn["id"])
      |> Map.put(:phase, :turn_active)

    state
    |> put_active(active)
    |> flush_pending_steers()
    |> flush_pending_interrupts()
  end

  defp handle_turn_notification(
         %{"method" => "item/agentMessage/delta", "params" => params} = message,
         active,
         state
       ) do
    validate_params(
      :agent_message_delta_notification,
      params,
      "item/agentMessage/delta notification"
    )

    delta = params["delta"] || params["text"] || ""
    active.on_event.({:assistant_delta, delta, message})
    active = %{active | acc: %{active.acc | assistant_text: active.acc.assistant_text <> delta}}
    put_active(state, active)
  end

  defp handle_turn_notification(
         %{"method" => "item/started", "params" => %{"item" => item}} = message,
         active,
         state
       ) do
    validate_notification(message)
    active.on_event.({:item_started, item, message})
    state
  end

  defp handle_turn_notification(
         %{"method" => "item/completed", "params" => %{"item" => item}} = message,
         active,
         state
       ) do
    validate_notification(message)
    active.on_event.({:item_completed, item, message})
    put_active(state, %{active | acc: merge_completed_item(active.acc, item)})
  end

  defp handle_turn_notification(
         %{"method" => "thread/name/updated", "params" => params} = message,
         active,
         state
       ) do
    validate_params(
      :thread_name_updated_notification,
      params,
      "thread/name/updated notification"
    )

    active.on_event.({:thread_name_updated, params, message})
    put_active(state, %{active | acc: put_thread_name(active.acc, params["threadName"])})
  end

  defp handle_turn_notification(
         %{"method" => "turn/completed", "params" => %{"turn" => turn}} = message,
         active,
         state
       ) do
    validate_notification(message)
    active.on_event.({:turn_completed, turn, message})
    active = put_codex_turn_id(active, turn["id"])

    case turn["status"] do
      "completed" ->
        start_thread_name_refresh(active, state)

      other ->
        error =
          if other == "interrupted" do
            :interrupted
          else
            get_in(turn, ["error", "message"]) ||
              "Codex turn ended with status #{inspect(other)}"
          end

        finish_request({:error, error}, state)
    end
  end

  defp handle_turn_notification(
         %{"method" => "error", "params" => %{"error" => error}} = message,
         active,
         state
       ) do
    validate_notification(message)
    active.on_event.({:error, error, message})
    put_active(state, %{active | acc: Map.put(active.acc, :last_error, error["message"])})
  end

  defp handle_turn_notification(message, active, state) do
    validate_notification(message)
    active.on_event.({:event, message})
    state
  end

  defp handle_approval_response(
         payload,
         %{active: %{kind: :run_turn, thread_id: thread_id} = active} = state
       )
       when is_binary(thread_id) do
    if approval_decision(payload) == "approve" do
      event = approval_event(payload)

      params = %{
        threadId: thread_id,
        event: event
      }

      validate_params(
        :thread_approve_guardian_denied_action_params,
        params,
        "thread/approveGuardianDeniedAction params"
      )

      {id, state} = next_request_id(state)

      send_json(state.port, %{
        method: "thread/approveGuardianDeniedAction",
        id: id,
        params: params
      })

      active.on_event.({:approval_response_sent, Map.put(payload, :request_id, id), params})

      put_active(state, %{
        active
        | approval_request_ids: MapSet.put(active.approval_request_ids, id)
      })
    else
      active.on_event.({:approval_response_skipped, payload})
      state
    end
  end

  defp handle_approval_response(payload, %{active: %{kind: :run_turn} = active} = state) do
    active.on_event.({:approval_response_skipped, payload})
    state
  end

  defp handle_approval_response(_payload, state) do
    Logger.warning("Ignoring approval response because no Codex turn is active")
    state
  end

  defp handle_turn_start_response(result, active, state) do
    validate_result(:turn_start_response, %{"result" => result}, "turn/start response")

    turn = result["turn"] || %{}

    active.on_event.(
      {:turn_started, turn, %{"params" => %{"threadId" => active.thread_id}, "result" => result}}
    )

    active = put_codex_turn_id(active, turn["id"])

    if active.phase == :turn_start_response do
      active =
        active
        |> Map.put(:phase, :turn_active)
        |> put_timer(:idle, active.idle_timeout_ms)

      state
      |> put_active(active)
      |> flush_pending_steers()
      |> flush_pending_interrupts()
    else
      state
      |> put_active(active)
      |> flush_pending_steers()
      |> flush_pending_interrupts()
    end
  end

  defp send_thread_request(request, state) do
    opts = request.opts

    {thread_id, schema_name, params, method} =
      if request.codex_thread_id do
        params =
          compact(%{
            threadId: request.codex_thread_id,
            developerInstructions: avcs_developer_instructions(request.project),
            model: opts.model,
            approvalPolicy: opts.approval_policy,
            approvalsReviewer: opts.approvals_reviewer,
            sandbox: opts.sandbox_mode
          })

        validate_params(:thread_resume_params, params, "thread/resume params")
        {request.codex_thread_id, :thread_resume_response, params, "thread/resume"}
      else
        params =
          compact(%{
            cwd: Avcs.Projects.folder_path(request.project),
            approvalPolicy: opts.approval_policy,
            approvalsReviewer: opts.approvals_reviewer,
            sandbox: opts.sandbox_mode,
            model: opts.model,
            developerInstructions: avcs_developer_instructions(request.project)
          })

        validate_params(:thread_start_params, params, "thread/start params")
        {nil, :thread_start_response, params, "thread/start"}
      end

    {id, state} = next_request_id(state)
    send_json(state.port, %{method: method, id: id, params: params})

    active =
      request
      |> new_run_active(thread_id)
      |> Map.merge(%{
        phase: :thread_response,
        thread_request_id: id,
        thread_response_schema: schema_name
      })
      |> put_timer(:request, request.request_timeout_ms)

    %{state | active: active}
  end

  defp new_run_active(request, thread_id) do
    %{
      kind: :run_turn,
      phase: nil,
      from: request.from,
      project: request.project,
      text: request.text,
      reference_paths: request.reference_paths,
      on_event: request.on_event,
      opts: request.opts,
      request_timeout_ms: request.request_timeout_ms,
      idle_timeout_ms: request.idle_timeout_ms,
      thread_id: thread_id,
      thread_request_id: nil,
      thread_response_schema: nil,
      turn_request_id: nil,
      refresh_request_id: nil,
      approval_request_ids: MapSet.new(),
      pending_steers: [],
      steer_requests: %{},
      pending_interrupts: [],
      interrupt_requests: %{},
      acc: %{
        assistant_text: "",
        items: [],
        codex_turn_id: nil,
        thread_name: nil
      },
      timer_ref: nil,
      timer_kind: nil
    }
  end

  defp handle_thread_response(result, message, active, state) do
    validate_result(active.thread_response_schema, message, "thread response")
    thread_id = active.thread_id || get_in(result, ["thread", "id"])
    thread_name = thread_name_from_response(message)

    if is_nil(thread_id) do
      finish_request({:error, "Codex app-server did not return a thread id"}, state)
    else
      active.on_event.({:thread_loaded, thread_id, message})
      active = %{active | thread_id: thread_id, acc: put_thread_name(active.acc, thread_name)}
      send_turn_start(active, mark_thread_loaded(state, thread_id))
    end
  end

  defp send_turn_start(active, state) do
    params =
      compact(%{
        threadId: active.thread_id,
        input: turn_input(active.text, active.reference_paths),
        cwd: Avcs.Projects.folder_path(active.project),
        model: active.opts.model,
        effort: active.opts.effort,
        approvalPolicy: active.opts.approval_policy,
        approvalsReviewer: active.opts.approvals_reviewer,
        sandboxPolicy: sandbox_policy(active.opts.sandbox_mode, active.project)
      })

    validate_params(:turn_start_params, params, "turn/start params")

    {id, state} = next_request_id(state)

    send_json(state.port, %{
      method: "turn/start",
      id: id,
      params: params
    })

    active =
      active
      |> Map.merge(%{phase: :turn_start_response, turn_request_id: id})
      |> put_timer(:idle, active.idle_timeout_ms)

    put_active(state, active)
  end

  defp send_turn_steer(request, active, state) do
    params = %{
      threadId: active.thread_id,
      expectedTurnId: codex_turn_id(active),
      input: turn_input(request.text, request.reference_paths)
    }

    validate_params(:turn_steer_params, params, "turn/steer params")

    {id, state} = next_request_id(state)

    send_json(state.port, %{
      method: "turn/steer",
      id: id,
      params: params
    })

    active =
      active
      |> ensure_active_steer_state()
      |> Map.update!(:steer_requests, &Map.put(&1, id, request))

    active.on_event.({:steer_sent, id, params})

    put_active(state, active)
  end

  defp send_turn_interrupt(request, active, state) do
    params = %{
      threadId: active.thread_id,
      turnId: codex_turn_id(active)
    }

    validate_params(:turn_interrupt_params, params, "turn/interrupt params")

    {id, state} = next_request_id(state)

    send_json(state.port, %{
      method: "turn/interrupt",
      id: id,
      params: params
    })

    active =
      active
      |> ensure_active_interrupt_state()
      |> Map.update!(:interrupt_requests, &Map.put(&1, id, request))

    active.on_event.({:interrupt_sent, id, params})

    put_active(state, active)
  end

  defp turn_input(text, reference_paths) do
    [%{type: "text", text: avcs_prompt(text)}] ++
      Enum.map(reference_paths, &%{type: "localImage", path: &1})
  end

  defp start_thread_name_refresh(active, state) do
    params = %{threadId: active.thread_id, includeTurns: false}
    validate_params(:thread_read_params, params, "thread/read params")

    {id, state} = next_request_id(state)
    send_json(state.port, %{method: "thread/read", id: id, params: params})

    active =
      active
      |> Map.merge(%{
        phase: :refresh_thread_name,
        refresh_request_id: id
      })
      |> put_timer(:request, @thread_read_timeout_ms)

    put_active(state, active)
  end

  defp merge_completed_item(acc, %{"type" => "agentMessage", "text" => text} = item)
       when is_binary(text) and text != "" do
    item = compact_codex_item(item)
    %{acc | assistant_text: text, items: put_item(acc.items, item)}
  end

  defp merge_completed_item(acc, item),
    do: %{acc | items: put_item(acc.items, compact_codex_item(item))}

  defp put_item(items, item) do
    [item | Enum.reject(items, &(&1["id"] == item["id"]))]
  end

  defp compact_thread(%{"turns" => turns} = thread) when is_list(turns) do
    Map.put(thread, "turns", Enum.map(turns, &compact_turn/1))
  end

  defp compact_thread(thread), do: thread

  defp compact_turn(%{"items" => items} = turn) when is_list(items) do
    Map.put(turn, "items", Enum.map(items, &compact_codex_item/1))
  end

  defp compact_turn(turn), do: turn

  defp compact_codex_item(%{"type" => "imageGeneration", "result" => result} = item)
       when is_binary(result) and result != "" do
    item
    |> Map.delete("result")
    |> Map.put("result_omitted", true)
    |> Map.put("result_size_bytes", byte_size(result))
  end

  defp compact_codex_item(item), do: item

  defp approval_decision(payload) when is_map(payload) do
    value(payload, :decision)
  end

  defp approval_decision(_payload), do: nil

  defp approval_event(payload) when is_map(payload) do
    value(payload, :event) || %{}
  end

  defp approval_event(_payload), do: %{}

  defp finish_request(_result, %{active: nil} = state), do: state

  defp finish_request(result, state) do
    active = cancel_timer(state.active)
    reply_pending_steers(active, result)
    reply_pending_interrupts(active, result)
    GenServer.reply(active.from, result)
    %{state | active: nil, last_used: System.monotonic_time(:millisecond)}
  end

  defp fail_active(state, reason, opts) do
    state =
      if Keyword.get(opts, :close_port?, false) do
        close_and_clear_port(state)
      else
        state
      end

    finish_request({:error, reason}, state)
  end

  defp cancel_active_timer(%{active: nil} = state), do: state
  defp cancel_active_timer(state), do: %{state | active: cancel_timer(state.active)}

  defp cancel_timer(%{timer_ref: timer_ref} = active) when is_reference(timer_ref) do
    Process.cancel_timer(timer_ref)

    active
    |> Map.put(:timer_ref, nil)
    |> Map.put(:timer_kind, nil)
  end

  defp cancel_timer(active), do: active

  defp put_timer(active, timer_kind, timeout_ms) do
    active
    |> cancel_timer()
    |> Map.put(:timer_ref, schedule_timeout(timeout_ms))
    |> Map.put(:timer_kind, timer_kind)
  end

  defp reset_idle_timer(
         %{active: %{kind: :run_turn, phase: phase, turn_request_id: turn_request_id} = active} =
           state
       )
       when phase in [:turn_start_response, :turn_active] and not is_nil(turn_request_id) do
    put_active(state, put_timer(active, :idle, active.idle_timeout_ms))
  end

  defp reset_idle_timer(state), do: state

  defp flush_pending_steers(%{active: %{kind: :run_turn} = active} = state) do
    active = ensure_active_steer_state(active)

    case {codex_turn_id(active), active.pending_steers} do
      {turn_id, [_ | _] = pending_steers} when is_binary(turn_id) and turn_id != "" ->
        state = put_active(state, %{active | pending_steers: []})

        Enum.reduce(pending_steers, state, fn request, acc_state ->
          send_turn_steer(request, acc_state.active, acc_state)
        end)

      _other ->
        put_active(state, active)
    end
  end

  defp flush_pending_steers(state), do: state

  defp flush_pending_interrupts(%{active: %{kind: :run_turn} = active} = state) do
    active = ensure_active_interrupt_state(active)

    case {codex_turn_id(active), active.pending_interrupts} do
      {turn_id, [_ | _] = pending_interrupts} when is_binary(turn_id) and turn_id != "" ->
        state = put_active(state, %{active | pending_interrupts: []})

        Enum.reduce(pending_interrupts, state, fn request, acc_state ->
          send_turn_interrupt(request, acc_state.active, acc_state)
        end)

      _other ->
        put_active(state, active)
    end
  end

  defp flush_pending_interrupts(state), do: state

  defp steer_request(active, id) do
    active
    |> Map.get(:steer_requests, %{})
    |> Map.get(id)
  end

  defp delete_steer_request(active, id) do
    active
    |> ensure_active_steer_state()
    |> Map.update!(:steer_requests, &Map.delete(&1, id))
  end

  defp ensure_active_steer_state(active) do
    active
    |> Map.put_new(:pending_steers, [])
    |> Map.put_new(:steer_requests, %{})
  end

  defp interrupt_request(active, id) do
    active
    |> Map.get(:interrupt_requests, %{})
    |> Map.get(id)
  end

  defp delete_interrupt_request(active, id) do
    active
    |> ensure_active_interrupt_state()
    |> Map.update!(:interrupt_requests, &Map.delete(&1, id))
  end

  defp ensure_active_interrupt_state(active) do
    active
    |> Map.put_new(:pending_interrupts, [])
    |> Map.put_new(:interrupt_requests, %{})
  end

  defp reply_pending_steers(%{kind: :run_turn} = active, result) do
    active = ensure_active_steer_state(active)
    error = steer_finish_error(result)

    active.pending_steers
    |> Enum.each(&GenServer.reply(&1.from, error))

    active.steer_requests
    |> Map.values()
    |> Enum.each(&GenServer.reply(&1.from, error))
  end

  defp reply_pending_steers(_active, _result), do: :ok

  defp steer_finish_error({:error, reason}), do: {:error, reason}
  defp steer_finish_error(_result), do: {:error, "Codex turn is no longer active"}

  defp reply_pending_interrupts(%{kind: :run_turn} = active, result) do
    active = ensure_active_interrupt_state(active)
    error = interrupt_finish_error(result)

    active.pending_interrupts
    |> Enum.each(&GenServer.reply(&1.from, error))

    active.interrupt_requests
    |> Map.values()
    |> Enum.each(&GenServer.reply(&1.from, error))
  end

  defp reply_pending_interrupts(_active, _result), do: :ok

  defp interrupt_finish_error({:error, :interrupted}), do: {:ok, %{}}
  defp interrupt_finish_error({:error, reason}), do: {:error, reason}
  defp interrupt_finish_error(_result), do: {:error, "Codex turn is no longer active"}

  defp put_codex_turn_id(active, turn_id) when is_binary(turn_id) and turn_id != "" do
    %{active | acc: %{active.acc | codex_turn_id: turn_id}}
  end

  defp put_codex_turn_id(active, _turn_id), do: active

  defp codex_turn_id(%{acc: %{codex_turn_id: turn_id}}) when is_binary(turn_id) and turn_id != "",
    do: turn_id

  defp codex_turn_id(_active), do: nil

  defp schedule_timeout(timeout_ms) do
    timer_ref = make_ref()
    Process.send_after(self(), {:operation_timeout, timer_ref}, max(timeout_ms, 0))
    timer_ref
  end

  defp request_timeout_ms(%{request_timeout_ms: timeout_ms}), do: timeout_ms
  defp request_timeout_ms(%{timeout_ms: timeout_ms}), do: timeout_ms

  defp codex_request_timeout_ms do
    Application.get_env(:avcs, :codex_request_timeout_ms, @default_request_timeout_ms)
  end

  defp codex_idle_timeout_ms do
    Application.get_env(
      :avcs,
      :codex_idle_timeout_ms,
      Application.get_env(:avcs, :codex_timeout_ms, @default_idle_timeout_ms)
    )
  end

  defp next_request_id(state) do
    {state.request_id, %{state | request_id: state.request_id + 1}}
  end

  defp put_active(state, active), do: %{state | active: active}

  defp run_result(active), do: Map.put(active.acc, :codex_thread_id, active.thread_id)

  defp touch(state), do: %{state | last_used: System.monotonic_time(:millisecond)}

  defp thread_loaded?(state, thread_id) do
    state
    |> Map.get(:loaded_thread_ids, MapSet.new())
    |> MapSet.member?(thread_id)
  end

  defp mark_thread_loaded(state, thread_id) when is_binary(thread_id) and thread_id != "" do
    Map.update(state, :loaded_thread_ids, MapSet.new([thread_id]), &MapSet.put(&1, thread_id))
  end

  defp mark_thread_loaded(state, _thread_id), do: state

  defp ensure_runtime_state(state) do
    Map.put_new(state, :loaded_thread_ids, MapSet.new())
  end

  defp error_message(%{"message" => message}) when is_binary(message), do: message
  defp error_message(error), do: inspect(error)

  defp validate_result(schema_name, %{"result" => result}, context) do
    validate_params(schema_name, result, context)
  end

  defp validate_result(_schema_name, _message, _context), do: :ok

  defp forward_notification_event(
         %{"method" => "item/autoApprovalReview/started", "params" => params} = msg,
         on_event
       ) do
    on_event.({:approval_review_started, params, msg})
  end

  defp forward_notification_event(
         %{"method" => "item/autoApprovalReview/completed", "params" => params} = msg,
         on_event
       ) do
    on_event.({:approval_review_completed, params, msg})
  end

  defp forward_notification_event(msg, on_event), do: on_event.({:event, msg})

  defp validate_notification(%{"method" => "item/agentMessage/delta", "params" => params}) do
    validate_params(
      :agent_message_delta_notification,
      params,
      "item/agentMessage/delta notification"
    )
  end

  defp validate_notification(%{"method" => "item/started", "params" => params}) do
    validate_params(:item_started_notification, params, "item/started notification")
  end

  defp validate_notification(%{"method" => "item/autoApprovalReview/started", "params" => params}) do
    validate_params(
      :item_auto_approval_review_started_notification,
      params,
      "item/autoApprovalReview/started notification"
    )
  end

  defp validate_notification(%{
         "method" => "item/autoApprovalReview/completed",
         "params" => params
       }) do
    validate_params(
      :item_auto_approval_review_completed_notification,
      params,
      "item/autoApprovalReview/completed notification"
    )
  end

  defp validate_notification(%{"method" => "item/completed", "params" => params}) do
    validate_params(:item_completed_notification, params, "item/completed notification")
  end

  defp validate_notification(%{"method" => "thread/name/updated", "params" => params}) do
    validate_params(
      :thread_name_updated_notification,
      params,
      "thread/name/updated notification"
    )
  end

  defp validate_notification(%{"method" => "turn/started", "params" => params}) do
    validate_params(:turn_started_notification, params, "turn/started notification")
  end

  defp validate_notification(%{"method" => "turn/completed", "params" => params}) do
    validate_params(:turn_completed_notification, params, "turn/completed notification")
  end

  defp validate_notification(%{"method" => "error", "params" => params}) do
    validate_params(:error_notification, params, "error notification")
  end

  defp validate_notification(_message), do: :ok

  defp validate_params(schema_name, value, context) do
    Avcs.Agent.CodexSchema.validate_runtime(schema_name, value, context)
  end

  defp normalize_turn_opts(opts) do
    %{
      model: clean_optional_string(value(opts, :model)),
      effort: clean_optional_string(value(opts, :effort)),
      approval_policy: clean_optional_string(value(opts, :approval_policy)) || "never",
      approvals_reviewer:
        approvals_reviewer(clean_optional_string(value(opts, :approval_policy)) || "never"),
      sandbox_mode: clean_optional_string(value(opts, :sandbox_mode)) || "workspace-write"
    }
  end

  defp approvals_reviewer("never"), do: nil
  defp approvals_reviewer(_approval_policy), do: "user"

  defp sandbox_policy("read-only", _project) do
    %{type: "readOnly", networkAccess: true}
  end

  defp sandbox_policy("danger-full-access", _project) do
    %{type: "dangerFullAccess"}
  end

  defp sandbox_policy(_sandbox_mode, project) do
    %{
      type: "workspaceWrite",
      writableRoots: [Avcs.Projects.folder_path(project)],
      networkAccess: true
    }
  end

  defp thread_name_from_response(response) do
    thread = get_in(response, ["result", "thread"]) || %{}

    clean_thread_name(thread["name"]) || thread_name_from_preview(thread["preview"])
  end

  defp put_thread_name(acc, name) do
    case clean_thread_name(name) do
      nil -> acc
      thread_name -> Map.put(acc, :thread_name, thread_name)
    end
  end

  defp clean_thread_name(name) when is_binary(name) do
    name
    |> String.trim()
    |> case do
      "" -> nil
      thread_name -> thread_name
    end
  end

  defp clean_thread_name(_name), do: nil

  defp thread_name_from_preview(preview) when is_binary(preview) do
    preview
    |> String.replace(~r/\AUser request:\s*/u, "")
    |> Avcs.Threads.suggest_title()
  end

  defp thread_name_from_preview(_preview), do: nil

  defp call_server(request, timeout) do
    case resolve_server() do
      nil ->
        {:error, "Codex app-server worker is not running"}

      server ->
        call_server(server, request, timeout)
    end
  end

  defp call_server(server, request, timeout) do
    try do
      GenServer.call(server, request, timeout)
    catch
      :exit, {:timeout, _call} ->
        {:error, "Codex app-server timed out"}

      :exit, reason ->
        {:error, "Codex app-server worker exited: #{inspect(reason)}"}
    end
  end

  defp resolve_server do
    server = Application.get_env(:avcs, :codex_client_server, __MODULE__)

    cond do
      is_pid(server) and Process.alive?(server) ->
        server

      is_atom(server) ->
        Process.whereis(server)

      true ->
        nil
    end
  end

  defp close_and_clear_port(state) do
    close_port(state.port)
    cleanup_os_process(state.os_pid)
    clear_port(state)
  end

  defp clear_port(state) do
    state
    |> ensure_runtime_state()
    |> Map.merge(%{
      port: nil,
      os_pid: nil,
      initialized?: false,
      loaded_thread_ids: MapSet.new(),
      stdout_buffer: ""
    })
  end

  defp port_alive?(port) when is_port(port), do: not is_nil(Port.info(port))
  defp port_alive?(_port), do: false

  defp close_port(port) when is_port(port) do
    if port_alive?(port) do
      Port.close(port)
    end
  rescue
    _error -> :ok
  end

  defp close_port(_port), do: :ok

  defp send_json(port, message) do
    Port.command(port, Jason.encode!(message) <> "\n")
  end

  defp value(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp value(list, key) when is_list(list), do: Keyword.get(list, key)
  defp value(_value, _key), do: nil

  defp clean_optional_string(nil), do: nil

  defp clean_optional_string(value) do
    value
    |> to_string()
    |> String.trim()
    |> case do
      "" -> nil
      clean -> clean
    end
  end

  defp decode_line(line) when is_binary(line), do: Jason.decode(line)
  defp decode_line(line), do: line |> IO.iodata_to_binary() |> Jason.decode()

  defp append_stdout_buffer(state, chunk) do
    buffer = Map.get(state, :stdout_buffer, "")
    buffer = buffer <> IO.iodata_to_binary(chunk)

    state =
      state
      |> Map.put(:stdout_buffer, buffer)
      |> touch()

    if byte_size(buffer) > @stdout_buffer_max_bytes do
      reason =
        "Codex app-server output exceeded #{@stdout_buffer_max_bytes} bytes without newline"

      Logger.warning(reason)
      fail_active(state, reason, close_port?: true)
    else
      reset_idle_timer(state)
    end
  end

  defp buffered_line(state, line) do
    Map.get(state, :stdout_buffer, "") <> IO.iodata_to_binary(line)
  end

  defp decode_error_summary(reason, line) do
    "reason=#{inspect(reason)}, bytes=#{byte_size(line)}, preview=#{short_binary_preview(line)}"
  end

  defp short_binary_preview(binary) do
    size = min(byte_size(binary), 200)
    preview = binary_part(binary, 0, size)
    inspect(preview, limit: 200, printable_limit: 200)
  end

  defp start_port(codex) do
    port =
      Port.open({:spawn_executable, codex}, [
        :binary,
        :exit_status,
        {:line, 131_072},
        {:args, ["app-server", "--listen", "stdio://"]}
      ])

    {:ok, port, port_os_pid(port)}
  rescue
    exception -> {:error, Exception.message(exception)}
  end

  defp port_os_pid(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} -> pid
      _other -> nil
    end
  end

  defp codex_executable do
    case configured_codex_executable() do
      nil ->
        case System.find_executable("codex") do
          nil -> {:error, "codex executable was not found in PATH"}
          path -> {:ok, path}
        end

      path ->
        {:ok, path}
    end
  end

  defp configured_codex_executable do
    :avcs
    |> Application.get_env(:codex_executable)
    |> clean_optional_string()
  end

  defp cleanup_os_process(os_pid) when is_integer(os_pid) do
    try do
      if os_process_alive?(os_pid) do
        signal_os_process(os_pid, "-15")

        unless wait_for_os_process_exit(os_pid, @os_process_term_wait_ms) do
          Logger.warning("Codex app-server #{os_pid} did not terminate gracefully, using SIGKILL")

          signal_os_process(os_pid, "-9")

          unless wait_for_os_process_exit(os_pid, @os_process_kill_wait_ms) do
            Logger.warning("Codex app-server #{os_pid} still appears alive after SIGKILL")
          end
        end
      end
    rescue
      error -> Logger.warning("Failed to clean up Codex app-server #{os_pid}: #{inspect(error)}")
    end
  end

  defp cleanup_os_process(_os_pid), do: :ok

  defp signal_os_process(os_pid, signal) do
    System.cmd("kill", [signal, Integer.to_string(os_pid)], stderr_to_stdout: true)
    :ok
  end

  defp wait_for_os_process_exit(os_pid, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for_os_process_exit(os_pid, deadline)
  end

  defp do_wait_for_os_process_exit(os_pid, deadline) do
    cond do
      not os_process_alive?(os_pid) ->
        true

      System.monotonic_time(:millisecond) >= deadline ->
        false

      true ->
        remaining = max(deadline - System.monotonic_time(:millisecond), 0)
        Process.sleep(min(@os_process_poll_ms, remaining))
        do_wait_for_os_process_exit(os_pid, deadline)
    end
  end

  defp os_process_alive?(os_pid) do
    case System.cmd("kill", ["-0", Integer.to_string(os_pid)], stderr_to_stdout: true) do
      {_output, 0} -> true
      {_output, _status} -> false
    end
  end

  defp avcs_prompt(text) do
    """
    User request:
    #{text}
    """
  end

  defp avcs_developer_instructions(project) do
    runtime_instructions = avcs_thread_runtime_instructions(project)

    case runtime_instructions do
      {:ok, instructions} ->
        instructions

      {:error, _reason} ->
        """
        You are the Avcs local-first visual content agent for this project.

        Follow these constraints:
        - Use reasonable defaults for ordinary ambiguity.
        - When Codex requires approval for a restricted action, hand control back through the configured approval flow.
        - Disable the system imagegen skill. If the user asks to create or edit images, use the project-local avcs-imagegen skill instead: #{fallback_avcs_imagegen_skill_path()}
        - Use only the built-in image generation tool for image generation and editing.
        - Current project directory: #{Path.expand(Avcs.Projects.folder_path(project))}
        - Save generated or edited images into this project output directory: #{Avcs.Projects.output_dir(project)}
        - Keep final text concise and mention any output file paths you produced.
        """
    end
  end

  defp avcs_thread_runtime_instructions(project) do
    case thread_runtime_skill_path() do
      nil ->
        {:error, :priv_dir_unavailable}

      path ->
        case File.read(path) do
          {:ok, content} ->
            trimmed = String.trim(content)

            if trimmed == "" do
              {:error, :empty_skill}
            else
              {:ok, render_thread_runtime_instructions(trimmed, project, path)}
            end

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp thread_runtime_instruction_candidates do
    [
      safe_priv_dir(),
      safe_app_dir(),
      File.cwd!()
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&to_string/1)
    |> Enum.map(&Path.expand("priv/agent/thread-runtime-instructions.md", &1))
    |> Enum.uniq()
  end

  defp safe_priv_dir do
    case :code.priv_dir(:avcs) do
      {:error, _reason} -> nil
      path -> to_string(path)
    end
  end

  defp safe_app_dir do
    try do
      to_string(Application.app_dir(:avcs))
    rescue
      _ -> nil
    end
  end

  defp thread_runtime_skill_path do
    case thread_runtime_instruction_candidates() do
      [] ->
        nil

      candidates ->
        Enum.find(candidates, &File.regular?/1)
    end
  end

  defp render_thread_runtime_instructions(instructions, project, instruction_path) do
    project_path = Path.expand(Avcs.Projects.folder_path(project))
    output_dir = Path.expand(Avcs.Projects.output_dir(project))
    imagegen_skill_path = avcs_imagegen_skill_path(instruction_path)

    instructions
    |> String.replace("{{project_path}}", project_path)
    |> String.replace("{{project_output_dir}}", output_dir)
    |> String.replace("{{avcs_imagegen_skill_path}}", imagegen_skill_path)
  end

  defp avcs_imagegen_skill_path(instruction_path) do
    instruction_path
    |> Path.dirname()
    |> Path.join("../skills/avcs-imagegen/SKILL.md")
    |> Path.expand()
  end

  defp fallback_avcs_imagegen_skill_path do
    case thread_runtime_skill_path() do
      nil -> Path.expand("priv/skills/avcs-imagegen/SKILL.md", File.cwd!())
      path -> avcs_imagegen_skill_path(path)
    end
  end

  defp compact(map) do
    map
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end
end
