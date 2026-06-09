defmodule Avcs.Agent.Harness.AvcsAgent do
  @moduledoc false

  @behaviour Avcs.Agent.Harness

  @impl true
  def run_turn(
        project,
        avcs_thread_id,
        avcs_turn_id,
        remote_thread_id,
        text,
        reference_paths,
        on_event,
        opts
      ) do
    settings = Avcs.SiteSettings.avcs_agent_runtime_settings()

    remote_thread_id =
      present_string(remote_thread_id) || "avcs-agent-thread-" <> Ecto.UUID.generate()

    remote_turn_id = "avcs-agent-turn-" <> Ecto.UUID.generate()

    on_event.(
      {:turn_started, %{"id" => remote_turn_id, "status" => "in_progress"},
       %{"params" => %{"threadId" => remote_thread_id}}}
    )

    with {:ok, context} <-
           Avcs.Agent.ContextTransform.build(
             project,
             avcs_thread_id,
             avcs_turn_id,
             text,
             reference_paths,
             opts
           ),
         {:ok, messages, compaction} <-
           maybe_compact(
             context.messages,
             settings.compact_threshold,
             project,
             avcs_thread_id,
             avcs_turn_id,
             remote_thread_id,
             remote_turn_id,
             settings.text_model,
             opts
           ) do
      loop_state =
        %{
          project: project,
          avcs_thread_id: avcs_thread_id,
          avcs_turn_id: avcs_turn_id,
          remote_thread_id: remote_thread_id,
          remote_turn_id: remote_turn_id,
          messages: messages,
          model_input_items: context.model_input_items,
          reference_assets: context.reference_assets,
          board_context: context.board_context,
          data_provider_context: context.data_provider_context,
          active_tools: context.active_tools,
          assistant_text: "",
          items: [],
          output_paths: [],
          pending_tool_calls: [],
          active_tool: nil,
          pending_steer_count: 0,
          queued_turn_input_count: 0,
          error: nil,
          settings: settings,
          opts: opts,
          on_event: on_event
        }
        |> trace_runtime_configuration()
        |> trace_context_transform(compaction)
        |> emit_snapshot("starting")

      case loop_until_no_pending_steer(loop_state) do
        {:ok, state} ->
          state = emit_snapshot(state, "completed")

          on_event.(
            {:turn_completed, %{"id" => remote_turn_id, "status" => "completed"},
             %{"params" => %{"threadId" => remote_thread_id}}}
          )

          {:ok,
           %{
             agent_harness: "avcs_agent",
             remote_thread_id: remote_thread_id,
             remote_turn_id: remote_turn_id,
             remote_model: state.settings.text_model,
             assistant_text: state.assistant_text,
             items: Enum.reverse(state.items),
             output_paths: Enum.reverse(state.output_paths),
             thread_name: nil
           }}

        {:error, :interrupted} ->
          {:error, :interrupted}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @impl true
  def active_turn(project, avcs_thread_id) do
    case Avcs.Turns.list_turns(project, avcs_thread_id) do
      {:ok, turns} ->
        turns
        |> Enum.reverse()
        |> Enum.find(&(&1["status"] in ["queued", "in_progress", "waiting_approval"]))
        |> case do
          nil -> :none
          turn -> {:ok, %{turn_id: turn["id"], status: turn["status"]}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def steer_turn(project, avcs_thread_id, text, reference_paths, opts) do
    case active_turn(project, avcs_thread_id) do
      {:ok, %{turn_id: turn_id}} ->
        case Registry.lookup(Avcs.Agent.RunnerRegistry, {avcs_thread_id, turn_id}) do
          [{pid, _value} | _rest] ->
            send(pid, {:avcs_agent_steer, turn_id, text, reference_paths, opts})
            {:ok, %{turn_id: turn_id, status: "queued"}}

          [] ->
            {:error, :not_running}
        end

      :none ->
        {:error, :not_running}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def interrupt_turn(_project, avcs_thread_id, avcs_turn_id) do
    case Registry.lookup(Avcs.Agent.RunnerRegistry, {avcs_thread_id, avcs_turn_id}) do
      [{pid, _value} | _rest] ->
        send(pid, {:avcs_agent_interrupt, avcs_turn_id})
        {:ok, %{turn_id: avcs_turn_id, status: "stopping"}}

      [] ->
        {:error, :not_running}
    end
  end

  @impl true
  def prepare_rerun(project, avcs_thread_id, avcs_turn_id, remote_thread_id, count, opts)
      when is_integer(count) and count > 0 do
    forked_thread_id = "avcs-agent-thread-" <> Ecto.UUID.generate()

    trace_event(project, %{
      scope: "thread",
      event_name: "thread/fork",
      thread_id: avcs_thread_id,
      turn_id: avcs_turn_id,
      agent_harness: "avcs_agent",
      remote_thread_id: forked_thread_id,
      status: "completed",
      payload: %{
        source_remote_thread_id: remote_thread_id,
        current_thread_path: "local_sqlite",
        branch_summary: %{
          reason: "edit_rerun",
          rollback_turn_count: count
        },
        settings: runtime_config_snapshot(opts)
      }
    })

    trace_event(project, %{
      scope: "thread",
      event_name: "thread/rollback",
      thread_id: avcs_thread_id,
      turn_id: avcs_turn_id,
      agent_harness: "avcs_agent",
      remote_thread_id: forked_thread_id,
      status: "completed",
      payload: %{
        current_thread_path: "local_sqlite",
        rollback_turn_count: count,
        note:
          "AvcsAgent rollback uses local SQLite invalidation and does not call Codex app-server."
      }
    })

    {:ok, %{remote_thread_id: forked_thread_id}}
  end

  def prepare_rerun(_project, _avcs_thread_id, _avcs_turn_id, _remote_thread_id, _count, _opts) do
    :ok
  end

  @impl true
  def read_thread(_remote_thread_id, _opts), do: {:error, :thread_read_unsupported}

  @impl true
  def respond_approval(_avcs_thread_id, _avcs_turn_id, _payload),
    do: {:error, :approval_response_unsupported}

  @impl true
  def list_models(_opts) do
    settings = Avcs.SiteSettings.avcs_agent_runtime_settings()

    {:ok,
     [
       %{"id" => settings.text_model, "owned_by" => "avcs_agent", "object" => "model"},
       %{"id" => settings.image_model, "owned_by" => "avcs_agent", "object" => "model"}
     ]}
  end

  def configured?, do: client().configured?()
  def available?, do: configured?()
  def pool_managed?, do: false

  defp loop_until_no_pending_steer(state) do
    case run_loop(state, 0) do
      {:ok, state} ->
        case drain_pending_steers(state) do
          {:ok, state, 0} -> {:ok, state}
          {:ok, state, _count} -> loop_until_no_pending_steer(state)
          {:interrupted, _state} -> {:error, :interrupted}
        end

      result ->
        result
    end
  end

  defp run_loop(state, step) do
    case drain_pending_steers(state) do
      {:interrupted, _state} ->
        {:error, :interrupted}

      {:ok, state, _steer_count} ->
        cond do
          step > state.settings.max_tool_steps ->
            {:ok, %{state | assistant_text: append_limit_note(state.assistant_text)}}

          true ->
            call_model(state)
            |> case do
              {:ok, %{tool_calls: []} = response} ->
                state = append_assistant_response(state, response)

                case drain_pending_steers(state) do
                  {:ok, state, 0} -> {:ok, state}
                  {:ok, state, _count} -> run_loop(state, step)
                  {:interrupted, _state} -> {:error, :interrupted}
                end

              {:ok, response} ->
                state =
                  state
                  |> append_assistant_response(response)
                  |> execute_tool_calls(response.tool_calls)
                  |> compact_state_messages()

                run_loop(state, step + 1)

              {:error, :interrupted} ->
                {:error, :interrupted}

              {:error, reason} ->
                maybe_complete_after_final_response_timeout(state, reason)
            end
        end
    end
  end

  defp call_model(state) do
    state = emit_snapshot(state, "model_streaming", %{is_streaming: true})

    client().chat_completion_stream(
      state.messages,
      Avcs.Agent.Tools.Registry.schemas(tool_opts(state)),
      [
        model: state.settings.text_model,
        trace_context: %{
          project: state.project,
          thread_id: state.avcs_thread_id,
          turn_id: state.avcs_turn_id,
          remote_thread_id: state.remote_thread_id,
          remote_turn_id: state.remote_turn_id,
          model: state.settings.text_model
        }
      ],
      state.on_event,
      &interrupted?/0
    )
  end

  defp append_assistant_response(state, response) do
    assistant_message =
      %{
        "role" => "assistant",
        "content" => response.assistant_text,
        "tool_calls" => openai_tool_calls(response.tool_calls)
      }
      |> compact_message()

    %{
      state
      | assistant_text: state.assistant_text <> response.assistant_text,
        messages: state.messages ++ [assistant_message]
    }
  end

  defp execute_tool_calls(state, tool_calls) do
    state = %{state | pending_tool_calls: Enum.map(tool_calls, & &1["id"])}
    state = emit_snapshot(state, "tool_calls_pending")

    Enum.reduce(tool_calls, state, fn tool_call, state ->
      state = %{state | active_tool: tool_call["name"]}
      state = emit_snapshot(state, "tool_call_started")

      started_item = %{
        "id" => tool_call["id"],
        "type" => "dynamicToolCall",
        "name" => tool_call["name"],
        "status" => "running",
        "arguments" => tool_call["arguments"]
      }

      state.on_event.({:item_started, started_item, event_raw(state)})

      {status, result} =
        case execute_tool_call(state, tool_call) do
          {:ok, result} -> {"completed", result}
          {:error, result} -> {"failed", result}
        end

      completed_item =
        started_item
        |> Map.put("status", status)
        |> Map.put("result", result)

      state.on_event.({:item_completed, completed_item, event_raw(state)})

      state = %{
        state
        | active_tool: nil,
          pending_tool_calls: List.delete(state.pending_tool_calls, tool_call["id"])
      }

      state = emit_snapshot(state, "tool_call_completed")

      tool_result_message = %{
        "role" => "tool",
        "tool_call_id" => tool_call["id"],
        "content" => Jason.encode!(result)
      }

      %{
        state
        | messages: state.messages ++ [tool_result_message],
          items: [completed_item | state.items],
          output_paths: state.output_paths
      }
    end)
  end

  defp maybe_complete_after_final_response_timeout(state, reason) do
    cond do
      not final_response_timeout?(reason) ->
        {:error, reason}

      image_output_paths(state) == [] ->
        {:error, reason}

      true ->
        state =
          state
          |> trace_final_response_timeout(reason)
          |> append_final_response_timeout_note(reason)

        {:ok, state}
    end
  end

  defp final_response_timeout?(:timeout), do: true

  defp final_response_timeout?(reason) when is_binary(reason) do
    reason
    |> String.downcase()
    |> String.contains?("timeout")
  end

  defp final_response_timeout?(_reason), do: false

  defp append_final_response_timeout_note(state, _reason) do
    note =
      case image_output_paths(state) do
        [path] ->
          "图片已生成并保存到 Output：#{path}。最终文字回复超时，已保留生成结果。"

        paths ->
          "图片已生成并保存到 Output：#{Enum.join(paths, ", ")}。最终文字回复超时，已保留生成结果。"
      end

    %{state | assistant_text: append_text_block(state.assistant_text, note)}
  end

  defp append_text_block("", addition), do: addition
  defp append_text_block(text, addition), do: text <> "\n\n" <> addition

  defp trace_final_response_timeout(state, reason) do
    trace_event(state.project, %{
      scope: "agent",
      event_name: "final_response_timeout",
      thread_id: state.avcs_thread_id,
      turn_id: state.avcs_turn_id,
      agent_harness: "avcs_agent",
      provider: "vercel_ai_gateway",
      model: state.settings.text_model,
      remote_thread_id: state.remote_thread_id,
      remote_turn_id: state.remote_turn_id,
      status: "completed",
      payload: %{
        reason: inspect(reason),
        degraded_to_completed: true,
        output_paths: image_output_paths(state)
      }
    })

    state
  end

  defp image_output_paths(state) do
    state.items
    |> Enum.filter(&successful_image_gen_item?/1)
    |> Enum.flat_map(fn item ->
      item
      |> get_in(["result", "assets"])
      |> List.wrap()
      |> Enum.flat_map(fn
        %{"relative_path" => "output/" <> _rest = path} -> [path]
        _asset -> []
      end)
    end)
    |> Enum.uniq()
  end

  defp successful_image_gen_item?(%{
         "name" => "image_gen",
         "status" => "completed",
         "result" => %{"status" => "completed", "assets" => assets}
       })
       when is_list(assets) and assets != [],
       do: true

  defp successful_image_gen_item?(_item), do: false

  defp execute_tool_call(state, tool_call) do
    context = %{
      project: state.project,
      thread_id: state.avcs_thread_id,
      turn_id: state.avcs_turn_id,
      remote_thread_id: state.remote_thread_id,
      remote_turn_id: state.remote_turn_id,
      tool_call_id: tool_call["id"],
      image_model: state.settings.image_model,
      base_url: state.settings.base_url,
      model: state.settings.text_model,
      data_provider_context: current_data_provider_context(state),
      progress: progress_callback(state, tool_call)
    }

    Avcs.Agent.Tools.Registry.execute(tool_call, context, tool_opts(state))
  end

  defp current_data_provider_context(%{data_provider_context: nil}), do: nil

  defp current_data_provider_context(state) do
    provider =
      get_in(state.data_provider_context || %{}, ["provider"]) ||
        get_in(state.data_provider_context || %{}, [:provider])

    Avcs.Agent.DataProvider.provider_context(provider, Enum.reverse(state.items || []))
  end

  defp progress_callback(state, tool_call) do
    fn status, payload ->
      progress_item = %{
        "id" => tool_call["id"],
        "type" => "dynamicToolCall",
        "name" => tool_call["name"],
        "status" => "running",
        "progress_status" => status,
        "progress" => payload,
        "arguments" => tool_call["arguments"]
      }

      state.on_event.({:item_updated, progress_item, event_raw(state)})
    end
  end

  defp drain_pending_steers(state) do
    case collect_pending_steers(state.avcs_turn_id, []) do
      {:interrupted, steers} ->
        {:interrupted, append_steer_messages(state, steers)}

      {:ok, steers} ->
        {:ok, append_steer_messages(state, steers), length(steers)}
    end
  end

  defp collect_pending_steers(turn_id, acc) do
    receive do
      {:avcs_agent_interrupt, ^turn_id} ->
        {:interrupted, Enum.reverse(acc)}

      {:avcs_agent_interrupt, _other_turn_id} ->
        collect_pending_steers(turn_id, acc)

      {:avcs_agent_steer, ^turn_id, text, reference_paths, opts} ->
        collect_pending_steers(turn_id, [
          %{text: text, reference_paths: reference_paths, opts: opts} | acc
        ])

      {:avcs_agent_steer, _other_turn_id, _text, _reference_paths, _opts} ->
        collect_pending_steers(turn_id, acc)
    after
      0 -> {:ok, Enum.reverse(acc)}
    end
  end

  defp append_steer_messages(state, []), do: state

  defp append_steer_messages(state, steers) do
    messages =
      Enum.flat_map(steers, fn steer ->
        opts =
          steer.opts
          |> opts_to_map()
          |> Map.put(:turn_continuation, true)

        case Avcs.Agent.ContextTransform.steer_user_message(
               state.project,
               steer.text,
               steer.reference_paths,
               opts
             ) do
          {:ok, message} ->
            [message]

          {:error, reason} ->
            [
              %{
                "role" => "system",
                "content" => "Queued turn input could not include image references: #{reason}",
                "avcs_kind" => "error"
              },
              %{"role" => "user", "content" => steer.text, "avcs_kind" => "queued_turn_input"}
            ]
        end
      end)

    next = %{
      state
      | messages: state.messages ++ messages,
        pending_steer_count: 0,
        queued_turn_input_count: length(steers)
    }

    emit_snapshot(next, "turn_continuation_queued")
  end

  defp event_raw(state), do: %{"params" => %{"threadId" => state.remote_thread_id}}

  defp maybe_compact(
         messages,
         threshold,
         project,
         thread_id,
         turn_id,
         remote_thread_id,
         remote_turn_id,
         model,
         opts
       ) do
    case Avcs.Agent.ContextCompaction.compact(messages, threshold, opts) do
      {:ok, compacted, %{compacted: true} = meta} ->
        trace_event(project, %{
          scope: "agent",
          event_name: "context_compaction",
          thread_id: thread_id,
          turn_id: turn_id,
          agent_harness: "avcs_agent",
          model: model,
          remote_thread_id: remote_thread_id,
          remote_turn_id: remote_turn_id,
          status: "completed",
          payload: meta
        })

        {:ok, compacted, meta}

      {:ok, compacted, meta} ->
        {:ok, compacted, meta}
    end
  end

  defp openai_tool_calls(tool_calls) do
    Enum.map(tool_calls, fn call ->
      %{
        "id" => call["id"],
        "type" => "function",
        "function" => %{"name" => call["name"], "arguments" => call["arguments"]}
      }
    end)
  end

  defp append_limit_note(""), do: "Tool step limit reached before the request completed."

  defp append_limit_note(text),
    do: text <> "\n\nTool step limit reached before the request completed."

  defp compact_state_messages(state) do
    case maybe_compact(
           state.messages,
           state.settings.compact_threshold,
           state.project,
           state.avcs_thread_id,
           state.avcs_turn_id,
           state.remote_thread_id,
           state.remote_turn_id,
           state.settings.text_model,
           state.opts
         ) do
      {:ok, messages, _meta} -> %{state | messages: messages}
      _result -> state
    end
  end

  defp tool_opts(state) do
    state.opts
    |> opts_to_map()
    |> Map.put(:active_tools, state.active_tools)
  end

  defp opts_to_map(opts) when is_map(opts), do: opts
  defp opts_to_map(opts) when is_list(opts), do: Map.new(opts)
  defp opts_to_map(_opts), do: %{}

  defp trace_runtime_configuration(state) do
    trace_event(state.project, %{
      scope: "agent",
      event_name: "runtime_configuration_changed",
      thread_id: state.avcs_thread_id,
      turn_id: state.avcs_turn_id,
      agent_harness: "avcs_agent",
      model: state.settings.text_model,
      remote_thread_id: state.remote_thread_id,
      remote_turn_id: state.remote_turn_id,
      status: "completed",
      payload: runtime_config_snapshot(state.opts, state.settings)
    })

    state
  end

  defp runtime_config_snapshot(opts, settings \\ nil) do
    %{
      "model" => value(opts, :model),
      "remote_model" => nil,
      "avcs_agent_text_model" => settings && settings.text_model,
      "reasoning_effort" => not_applicable(value(opts, :effort)),
      "approval_policy" => not_applicable(value(opts, :approval_policy) || "never"),
      "sandbox_mode" => not_applicable(value(opts, :sandbox_mode) || "workspace-write"),
      "active_tools" =>
        value(opts, :active_tools) || value(opts, :active_tool_names) ||
          Avcs.Agent.Tools.Registry.default_active_tools(),
      "unsupported_codex_only" => %{
        "reasoning_effort" => "not_applicable",
        "approval_policy" => "not_applicable",
        "sandbox_mode" => "not_applicable"
      }
    }
    |> compact_payload()
  end

  defp not_applicable(nil), do: %{"status" => "not_applicable"}
  defp not_applicable(value), do: %{"value" => value, "status" => "not_applicable"}

  defp trace_context_transform(state, compaction) do
    trace_event(state.project, %{
      scope: "agent",
      event_name: "context_transform",
      thread_id: state.avcs_thread_id,
      turn_id: state.avcs_turn_id,
      agent_harness: "avcs_agent",
      model: state.settings.text_model,
      remote_thread_id: state.remote_thread_id,
      remote_turn_id: state.remote_turn_id,
      status: "completed",
      payload: %{
        model_input_items: state.model_input_items,
        reference_assets: state.reference_assets,
        board_context_count: length(state.board_context || []),
        data_provider_context_present: not is_nil(state.data_provider_context),
        active_tools: state.active_tools,
        compaction: compaction
      }
    })

    state
  end

  defp emit_snapshot(state, phase, overrides \\ %{}) do
    snapshot =
      %{
        phase: phase,
        is_streaming: Map.get(overrides, :is_streaming, false),
        current_assistant_item: current_assistant_item(state),
        pending_tool_calls: state.pending_tool_calls || [],
        error: state.error,
        active_tool: state.active_tool,
        pending_steer: (state.pending_steer_count || 0) > 0,
        queued_turn_input: state.queued_turn_input_count || 0
      }
      |> Map.merge(overrides)

    state.on_event.({:avcs_agent_state_snapshot, snapshot, event_raw(state)})
    state
  end

  defp current_assistant_item(%{assistant_text: ""}), do: nil

  defp current_assistant_item(state) do
    %{
      "type" => "assistant_message",
      "content" => String.slice(state.assistant_text, 0, 2_000)
    }
  end

  defp trace_event(project, attrs) do
    case Avcs.Trace.append_event(project, attrs) do
      {:ok, _event} -> :ok
      _result -> :ok
    end
  end

  defp compact_payload(map) do
    map
    |> Enum.reject(fn {_key, value} -> value in [nil, "", [], %{}] end)
    |> Map.new()
  end

  defp compact_message(message) do
    message
    |> Enum.reject(fn {_key, value} -> is_nil(value) or value == "" or value == [] end)
    |> Map.new()
  end

  defp present_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      clean -> clean
    end
  end

  defp present_string(_value), do: nil

  defp value(opts, key) when is_map(opts),
    do: Map.get(opts, key) || Map.get(opts, Atom.to_string(key))

  defp value(opts, key) when is_list(opts), do: Keyword.get(opts, key)
  defp value(_opts, _key), do: nil

  defp interrupted? do
    receive do
      {:avcs_agent_interrupt, _turn_id} -> true
    after
      0 -> false
    end
  end

  defp client do
    Application.get_env(:avcs, :avcs_agent_client, Avcs.Agent.AvcsAgentClient)
  end
end
