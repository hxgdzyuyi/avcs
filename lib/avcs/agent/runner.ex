defmodule Avcs.Agent.Runner do
  @moduledoc false

  require Logger

  def submit(project, thread_id, text, asset_ids, turn_settings \\ %{}) do
    codex_client = Application.get_env(:avcs, :codex_client, Avcs.Agent.CodexAppServerPool)

    case active_codex_turn(codex_client, project, thread_id) do
      {:ok, active} ->
        steer_active_turn(
          codex_client,
          project,
          thread_id,
          active.turn_id,
          text,
          asset_ids,
          turn_settings
        )

      :none ->
        create_and_start_turn(project, thread_id, text, asset_ids, turn_settings, codex_client)
    end
  end

  def start(project, thread_id, turn_id, text, asset_ids, turn_settings \\ %{}) do
    Task.Supervisor.start_child(Avcs.Agent.TaskSupervisor, fn ->
      run(project, thread_id, turn_id, text, asset_ids, turn_settings)
    end)
  end

  def rerun_from_item(project, item_id, content, turn_settings \\ %{}) do
    codex_client = Application.get_env(:avcs, :codex_client, Avcs.Agent.CodexAppServerPool)
    status = if pool_managed_client?(codex_client), do: "queued", else: "in_progress"

    with {:ok, edited} <-
           Avcs.Turns.edit_and_invalidate_after(project, item_id, content, status: status),
         rerun_settings <- Map.merge(edited["turn_settings"] || %{}, turn_settings || %{}),
         :ok <-
           prepare_codex_thread_for_rerun(
             codex_client,
             project,
             edited["turn"]["thread_id"],
             edited["turn"]["id"],
             edited["rollback_turn_count"],
             rerun_settings
           ),
         {:ok, _pid} <-
           start(
             project,
             edited["turn"]["thread_id"],
             edited["turn"]["id"],
             edited["item"]["content"],
             edited["asset_ids"],
             rerun_settings
           ) do
      Avcs.Events.broadcast("item:updated", %{
        thread_id: edited["turn"]["thread_id"],
        turn_id: edited["turn"]["id"],
        item: edited["item"]
      })

      broadcast_thread_items(project, edited["turn"]["thread_id"])

      Avcs.Events.broadcast("turn:started", %{
        thread_id: edited["turn"]["thread_id"],
        turn_id: edited["turn"]["id"],
        turn: edited["turn"]
      })

      broadcast_threads(project)
      Avcs.Projects.broadcast_projects_updated()

      {:ok, edited}
    end
  end

  def respond_approval(thread_id, turn_id, payload) do
    case Registry.lookup(Avcs.Agent.RunnerRegistry, {thread_id, turn_id}) do
      [{pid, _value} | _rest] ->
        send(pid, {:approval_response, payload})
        forward_codex_approval(thread_id, turn_id, payload)
        :ok

      [] ->
        {:error, :not_running}
    end
  end

  def stop(project, thread_id, turn_id) do
    codex_client = Application.get_env(:avcs, :codex_client, Avcs.Agent.CodexAppServerPool)

    cond do
      module_exports?(codex_client, :interrupt_turn, 3) ->
        codex_client.interrupt_turn(project, thread_id, turn_id)

      true ->
        {:error, :interrupt_unsupported}
    end
  end

  def repair_thread(project, thread_id) do
    with {:ok, thread} <- Avcs.Threads.get_thread(project, thread_id),
         {:ok, %{"codex_thread_id" => codex_thread_id} = thread}
         when is_binary(codex_thread_id) and codex_thread_id != "" <-
           repairable_thread(project, thread),
         {:ok, codex_thread} <- read_codex_thread(project, thread_id, codex_thread_id),
         {:ok, repair} <- reconcile_codex_thread(project, thread, codex_thread) do
      broadcast_lists(project, thread_id)
      {:ok, repair}
    else
      {:ok, nil} ->
        {:error, :thread_not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp active_codex_turn(codex_client, project, thread_id) do
    if module_exports?(codex_client, :active_turn, 2) do
      codex_client.active_turn(project, thread_id)
    else
      :none
    end
  end

  defp steer_active_turn(
         codex_client,
         project,
         thread_id,
         turn_id,
         text,
         asset_ids,
         turn_settings
       ) do
    with {:ok, item} <-
           append_steered_user_item(project, thread_id, turn_id, text, asset_ids, turn_settings),
         {:ok, reference_paths} <-
           resolve_reference_paths(project, asset_ids, thread_id, turn_id),
         :ok <-
           steer_codex_turn(
             codex_client,
             project,
             thread_id,
             text,
             reference_paths,
             turn_settings
           ),
         {:ok, turn} <- Avcs.Turns.get_turn(project, turn_id) do
      Avcs.Events.broadcast("item:created", %{
        thread_id: thread_id,
        turn_id: turn_id,
        item: item
      })

      {:ok, %{"turn" => turn, "item" => item, "steered" => true}}
    else
      {:error, reason} ->
        Avcs.Events.broadcast("error", %{
          thread_id: thread_id,
          turn_id: turn_id,
          message: to_string(reason),
          scope: "agent"
        })

        {:error, reason}
    end
  end

  defp append_steered_user_item(project, thread_id, turn_id, text, asset_ids, turn_settings) do
    Avcs.Turns.append_item(project,
      turn_id: turn_id,
      thread_id: thread_id,
      type: "user_message",
      role: "user",
      content: text,
      payload: steered_payload(asset_ids, turn_settings)
    )
  end

  defp steer_codex_turn(codex_client, project, thread_id, text, reference_paths, turn_settings) do
    if module_exports?(codex_client, :steer_turn, 5) do
      case codex_client.steer_turn(
             project,
             thread_id,
             agent_text_for(project, text, turn_settings),
             reference_paths,
             []
           ) do
        {:ok, _response} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :steer_unsupported}
    end
  end

  defp steered_payload(asset_ids, turn_settings) do
    %{asset_ids: asset_ids, steered: true}
    |> maybe_put_mask_edit(mask_edit(turn_settings))
    |> maybe_put_data_provider(data_provider(turn_settings))
  end

  defp maybe_put_mask_edit(payload, nil), do: payload
  defp maybe_put_mask_edit(payload, mask_edit), do: Map.put(payload, :mask_edit, mask_edit)

  defp maybe_put_data_provider(payload, nil), do: payload

  defp maybe_put_data_provider(payload, data_provider),
    do: Map.put(payload, :data_provider, data_provider)

  defp agent_text_for(project, text, turn_settings) do
    text
    |> append_mask_edit_instructions(turn_settings)
    |> append_data_provider_instructions(project, turn_settings)
  end

  defp append_mask_edit_instructions(text, turn_settings) do
    case mask_edit(turn_settings) do
      nil ->
        text

      _mask_edit ->
        """
        #{text}

        Mask edit reference instructions:
        - The first referenced image is the base image to edit.
        - The second referenced image is a mask image.
        - In the mask image, white or marked areas indicate the region to change.
        - Black or unmarked areas indicate regions that should remain as close to the base image as possible.
        - Use the mask as a visual reference. This is not a formal API mask, so preserve unchanged areas as carefully as the available image tool allows.
        """
        |> String.trim()
    end
  end

  defp append_data_provider_instructions(text, project, turn_settings) do
    case Avcs.Agent.DataProvider.runner_instructions(project, data_provider(turn_settings)) do
      nil ->
        text

      instructions ->
        """
        #{text}

        #{instructions}
        """
        |> String.trim()
    end
  end

  defp mask_edit(turn_settings) when is_map(turn_settings) do
    Map.get(turn_settings, :mask_edit) || Map.get(turn_settings, "mask_edit")
  end

  defp mask_edit(_turn_settings), do: nil

  defp data_provider(turn_settings) when is_map(turn_settings) do
    Map.get(turn_settings, :data_provider) || Map.get(turn_settings, "data_provider")
  end

  defp data_provider(_turn_settings), do: nil

  defp prepare_codex_thread_for_rerun(
         _codex_client,
         _project,
         _thread_id,
         _turn_id,
         rollback_count,
         _settings
       )
       when not is_integer(rollback_count) or rollback_count <= 0 do
    :ok
  end

  defp prepare_codex_thread_for_rerun(
         codex_client,
         project,
         thread_id,
         turn_id,
         rollback_count,
         settings
       ) do
    trace_opts = codex_thread_trace_opts(project, thread_id, turn_id, settings)

    with {:ok, %{"codex_thread_id" => codex_thread_id}}
         when is_binary(codex_thread_id) and
                codex_thread_id != "" <-
           Avcs.Threads.get_thread(project, thread_id),
         true <- module_exports?(codex_client, :fork_thread, 2),
         true <- module_exports?(codex_client, :rollback_thread, 3),
         {:ok, forked_thread} <- codex_client.fork_thread(codex_thread_id, trace_opts),
         forked_thread_id when is_binary(forked_thread_id) and forked_thread_id != "" <-
           forked_thread["id"],
         {:ok, rolled_back_thread} <-
           codex_client.rollback_thread(forked_thread_id, rollback_count, trace_opts),
         rolled_back_thread_id
         when is_binary(rolled_back_thread_id) and rolled_back_thread_id != "" <-
           rolled_back_thread["id"] || forked_thread_id,
         :ok <-
           persist_codex_thread_id(project, thread_id, rolled_back_thread_id, :edit_rerun) do
      :ok
    else
      {:ok, _thread_without_codex_id} ->
        :ok

      false ->
        fallback_to_new_codex_thread(project, thread_id, :unsupported)

      {:error, reason} ->
        fallback_to_new_codex_thread(project, thread_id, reason)

      reason ->
        fallback_to_new_codex_thread(project, thread_id, reason)
    end
  end

  defp codex_thread_trace_opts(project, thread_id, turn_id, settings) do
    settings
    |> map_to_option_list()
    |> Kernel.++(
      project: project,
      avcs_thread_id: thread_id,
      avcs_turn_id: turn_id
    )
  end

  defp map_to_option_list(value) when is_map(value), do: Map.to_list(value)
  defp map_to_option_list(value) when is_list(value), do: value
  defp map_to_option_list(_value), do: []

  defp fallback_to_new_codex_thread(project, thread_id, reason) do
    trace_event(project, %{
      scope: "agent",
      event_name: "edit_rerun_codex_thread_reset",
      thread_id: thread_id,
      payload: %{reason: inspect(reason)}
    })

    case Avcs.Threads.set_codex_thread_id(project, thread_id, nil) do
      {:ok, :ok} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  defp create_and_start_turn(project, thread_id, text, asset_ids, turn_settings, codex_client) do
    status = if pool_managed_client?(codex_client), do: "queued", else: "in_progress"
    turn_settings = Map.put(turn_settings, :status, status)

    with {:ok, created} <-
           Avcs.Turns.create_user_turn(project, thread_id, text, asset_ids, turn_settings),
         {:ok, _pid} <-
           start(
             project,
             thread_id,
             created["turn"]["id"],
             text,
             asset_ids,
             turn_settings
           ) do
      Avcs.Events.broadcast("turn:started", %{
        thread_id: thread_id,
        turn_id: created["turn"]["id"],
        turn: created["turn"]
      })

      Avcs.Events.broadcast("item:created", %{
        thread_id: thread_id,
        turn_id: created["turn"]["id"],
        item: created["item"]
      })

      broadcast_threads(project)
      Avcs.Projects.broadcast_projects_updated()

      {:ok, created}
    end
  end

  defp run(project, thread_id, turn_id, text, asset_ids, turn_settings) do
    {:ok, _registry} = Registry.register(Avcs.Agent.RunnerRegistry, {thread_id, turn_id}, nil)
    before_hashes = output_hashes(project)
    {:ok, thread} = Avcs.Threads.get_thread(project, thread_id)
    codex_client = Application.get_env(:avcs, :codex_client, Avcs.Agent.CodexAppServerPool)

    with {:ok, reference_paths} <- resolve_reference_paths(project, asset_ids, thread_id, turn_id) do
      unless pool_managed_client?(codex_client) do
        Avcs.Events.broadcast("agent:run_started", %{thread_id: thread_id, turn_id: turn_id})
      end

      on_event = fn event -> forward_agent_event(project, thread_id, turn_id, event) end

      case run_codex_turn(
             codex_client,
             project,
             thread["codex_thread_id"],
             agent_text_for(project, text, turn_settings),
             reference_paths,
             on_event,
             Map.merge(turn_settings, %{avcs_thread_id: thread_id, avcs_turn_id: turn_id})
           ) do
        {:ok, result} ->
          case persist_codex_thread_id(
                 project,
                 thread_id,
                 result.codex_thread_id,
                 :run_completed
               ) do
            :ok ->
              sync_thread_title(project, thread_id, Map.get(result, :thread_name))

              provider_context =
                Avcs.Agent.DataProvider.provider_context(
                  data_provider(turn_settings),
                  result.items
                )

              if String.trim(result.assistant_text) != "" do
                {:ok, item} =
                  Avcs.Turns.append_item(project,
                    turn_id: turn_id,
                    thread_id: thread_id,
                    type: "assistant_message",
                    role: "assistant",
                    content: result.assistant_text,
                    payload:
                      %{
                        codex_items:
                          result.items |> Enum.take(50) |> Enum.map(&persistable_codex_item/1)
                      }
                      |> maybe_put_provider_context(provider_context)
                  )

                Avcs.Events.broadcast("item:created", %{
                  thread_id: thread_id,
                  turn_id: turn_id,
                  item: item
                })
              end

              Avcs.Turns.complete_turn(project, turn_id, result.codex_turn_id)

              register_image_outputs(
                project,
                thread_id,
                turn_id,
                result.items,
                before_hashes,
                text,
                provider_context
              )

              Avcs.Threads.touch(project, thread_id)
              broadcast_lists(project, thread_id)

              Avcs.Events.broadcast("agent:run_completed", %{
                thread_id: thread_id,
                turn_id: turn_id,
                status: "completed"
              })

            {:error, reason} ->
              fail_agent_turn(project, thread_id, turn_id, persist_failure_message(reason))
          end

        {:error, :interrupted} ->
          interrupt_agent_turn(project, thread_id, turn_id)

        {:error, reason} ->
          fail_agent_turn(project, thread_id, turn_id, reason)
      end
    else
      {:error, reason} ->
        fail_agent_turn(project, thread_id, turn_id, reason)
    end
  end

  defp resolve_reference_paths(project, asset_ids, thread_id, turn_id) do
    requested_asset_ids = List.wrap(asset_ids)

    {reference_paths, missing_asset_ids} =
      Enum.reduce(requested_asset_ids, {[], MapSet.new()}, fn asset_id, {paths, missing} ->
        case resolve_reference_path(project, asset_id) do
          {:ok, path} -> {[path | paths], missing}
          :missing -> {paths, MapSet.put(missing, asset_id)}
        end
      end)

    reference_paths = Enum.reverse(reference_paths)

    if Enum.empty?(missing_asset_ids) do
      trace_event(project, %{
        scope: "agent",
        event_name: "assets:resolved",
        thread_id: thread_id,
        turn_id: turn_id,
        payload: %{
          requested_asset_ids: requested_asset_ids,
          resolved_count: length(reference_paths)
        }
      })

      {:ok, reference_paths}
    else
      missing_asset_ids = MapSet.to_list(missing_asset_ids)

      trace_event(project, %{
        scope: "agent",
        event_name: "assets:resolve_failed",
        thread_id: thread_id,
        turn_id: turn_id,
        status: "failed",
        payload: %{requested_asset_ids: requested_asset_ids, missing_asset_ids: missing_asset_ids}
      })

      {:error,
       "Cannot resolve reference paths: missing or invalid asset_ids " <>
         inspect(missing_asset_ids)}
    end
  end

  defp resolve_reference_path(project, asset_id) do
    case Avcs.Assets.get_asset(project, asset_id) do
      {:ok, %{"file_path" => file_path}} when is_binary(file_path) ->
        if File.exists?(file_path) do
          {:ok, file_path}
        else
          :missing
        end

      {:ok, _asset} ->
        :missing

      {:error, _reason} ->
        :missing

      _ ->
        :missing
    end
  end

  defp forward_agent_event(project, thread_id, turn_id, event) do
    broadcast_thinking_tick(thread_id, turn_id, event)
    forward_event(project, thread_id, turn_id, event)
  end

  defp broadcast_thinking_tick(thread_id, turn_id, event) do
    Avcs.Events.broadcast("agent:thinking_tick", %{
      thread_id: thread_id,
      turn_id: turn_id,
      event_name: thinking_event_name(event),
      status: thinking_event_status(event)
    })
  end

  defp thinking_event_name({:assistant_delta, _delta, _raw}), do: "item/agentMessage/delta"
  defp thinking_event_name({:item_started, _item, _raw}), do: "item/started"
  defp thinking_event_name({:item_completed, _item, _raw}), do: "item/completed"
  defp thinking_event_name({:turn_started, _turn, _raw}), do: "turn/started"
  defp thinking_event_name({:turn_completed, _turn, _raw}), do: "turn/completed"
  defp thinking_event_name({:thread_loaded, _thread_id, _raw}), do: "thread/loaded"
  defp thinking_event_name({:thread_name_updated, _params, _raw}), do: "thread/name/updated"

  defp thinking_event_name({:approval_review_started, _params, _raw}),
    do: "item/autoApprovalReview/started"

  defp thinking_event_name({:approval_review_completed, _params, _raw}),
    do: "item/autoApprovalReview/completed"

  defp thinking_event_name({:error, _error, _raw}), do: "error"
  defp thinking_event_name({:event, %{"method" => method}}) when is_binary(method), do: method

  defp thinking_event_name(event) when is_tuple(event) and tuple_size(event) > 0 do
    event
    |> elem(0)
    |> to_string()
  end

  defp thinking_event_name(_event), do: "event"

  defp thinking_event_status({:pool_queued, _meta}), do: "queued"
  defp thinking_event_status({:approval_review_started, _params, _raw}), do: "waiting_approval"
  defp thinking_event_status({:error, _error, _raw}), do: "error"

  defp thinking_event_status({:turn_completed, turn, _raw}) do
    turn["status"] || "completed"
  end

  defp thinking_event_status(_event), do: "running"

  defp forward_event(_project, thread_id, turn_id, {:assistant_delta, delta, _raw})
       when delta != "" do
    Avcs.Events.broadcast("assistant:delta", %{
      thread_id: thread_id,
      turn_id: turn_id,
      delta: delta
    })
  end

  defp forward_event(project, _thread_id, turn_id, {:pool_queued, _meta}) do
    {:ok, _turn} = Avcs.Turns.update_turn_status(project, turn_id, "queued", nil)
    :ok
  end

  defp forward_event(project, thread_id, turn_id, {:pool_worker_assigned, _meta}) do
    {:ok, turn} = Avcs.Turns.update_turn_status(project, turn_id, "in_progress", nil)

    Avcs.Events.broadcast("turn:started", %{
      thread_id: thread_id,
      turn_id: turn_id,
      turn: turn
    })

    Avcs.Events.broadcast("agent:run_started", %{thread_id: thread_id, turn_id: turn_id})
  end

  defp forward_event(project, thread_id, turn_id, {:item_started, item, raw}) do
    if tool_item?(item) do
      ensure_codex_thread_id(project, thread_id, codex_thread_id_from_raw(raw), :item_started)

      {:ok, avcs_item} =
        Avcs.Turns.upsert_codex_item(project,
          turn_id: turn_id,
          thread_id: thread_id,
          codex_item_id: item["id"],
          type: "tool_call",
          role: "tool",
          content: tool_summary(item),
          status: "running",
          payload: %{codex_item: persistable_codex_item(item), tool_name: tool_name(item)}
        )

      trace_event(project, %{
        scope: "item",
        event_name: "item_started",
        thread_id: thread_id,
        turn_id: turn_id,
        item_id: avcs_item["id"],
        codex_thread_id: codex_thread_id_from_raw(raw),
        codex_item_id: item["id"],
        status: "running",
        payload: %{item: item},
        raw: raw
      })

      Avcs.Events.broadcast("item:created", %{
        thread_id: thread_id,
        turn_id: turn_id,
        item: avcs_item
      })

      Avcs.Events.broadcast("tool:updated", %{
        thread_id: thread_id,
        turn_id: turn_id,
        item: avcs_item,
        status: "running"
      })
    end
  end

  defp forward_event(project, thread_id, _turn_id, {:thread_loaded, codex_thread_id, _raw}) do
    ensure_codex_thread_id(project, thread_id, codex_thread_id, :thread_loaded)
    :ok
  end

  defp forward_event(project, thread_id, turn_id, {:turn_started, turn, raw}) do
    ensure_codex_thread_id(project, thread_id, codex_thread_id_from_raw(raw), :turn_started)

    if is_binary(turn["id"]) and turn["id"] != "" do
      {:ok, _turn} = Avcs.Turns.update_turn_status(project, turn_id, "in_progress", turn["id"])
    end

    trace_event(project, %{
      scope: "turn",
      event_name: "turn_started",
      thread_id: thread_id,
      turn_id: turn_id,
      codex_thread_id: codex_thread_id_from_raw(raw),
      codex_turn_id: turn["id"],
      status: turn["status"] || "in_progress",
      payload: %{turn: turn},
      raw: raw
    })
  end

  defp forward_event(project, thread_id, turn_id, {:item_completed, item, raw}) do
    if tool_item?(item) do
      ensure_codex_thread_id(project, thread_id, codex_thread_id_from_raw(raw), :item_completed)

      status = tool_status(item)

      {:ok, avcs_item} =
        Avcs.Turns.upsert_codex_item(project,
          turn_id: turn_id,
          thread_id: thread_id,
          codex_item_id: item["id"],
          type: "tool_result",
          role: "tool",
          content: tool_summary(item),
          status: status,
          payload: %{codex_item: persistable_codex_item(item), tool_name: tool_name(item)}
        )

      trace_event(project, %{
        scope: "item",
        event_name: "item_completed",
        thread_id: thread_id,
        turn_id: turn_id,
        item_id: avcs_item["id"],
        codex_thread_id: codex_thread_id_from_raw(raw),
        codex_item_id: item["id"],
        status: status,
        payload: %{item: item},
        raw: raw
      })

      Avcs.Events.broadcast("item:updated", %{
        thread_id: thread_id,
        turn_id: turn_id,
        item: avcs_item
      })

      Avcs.Events.broadcast("tool:updated", %{
        thread_id: thread_id,
        turn_id: turn_id,
        item: avcs_item,
        status: status
      })

      persist_image_generation_output_on_item_completed(
        project,
        thread_id,
        turn_id,
        item,
        item["prompt"] || item["revisedPrompt"] || item["savedPath"] || "Image generation"
      )
    end
  end

  defp forward_event(project, thread_id, turn_id, {:approval_review_started, params, raw}) do
    ensure_codex_thread_id(project, thread_id, params["threadId"], :approval_review_started)

    {:ok, avcs_item} =
      Avcs.Turns.upsert_codex_item(
        project,
        Avcs.Agent.ApprovalReview.started_item_attrs(thread_id, turn_id, params, raw)
      )

    Avcs.Turns.update_turn_status(project, turn_id, "waiting_approval", nil)

    trace_event(project, %{
      scope: "approval",
      event_name: "approval_review_started",
      thread_id: thread_id,
      turn_id: turn_id,
      item_id: avcs_item["id"],
      codex_thread_id: params["threadId"],
      codex_turn_id: params["turnId"],
      codex_item_id: avcs_item["codex_item_id"],
      status: avcs_item["status"],
      payload: params,
      raw: raw
    })

    payload = approval_payload(thread_id, turn_id, avcs_item)
    Avcs.Events.broadcast("item:created", payload)
    Avcs.Events.broadcast("approval:requested", payload)
  end

  defp forward_event(project, thread_id, turn_id, {:approval_review_completed, params, raw}) do
    ensure_codex_thread_id(project, thread_id, params["threadId"], :approval_review_completed)

    {:ok, avcs_item} =
      Avcs.Turns.upsert_codex_item(
        project,
        Avcs.Agent.ApprovalReview.completed_item_attrs(thread_id, turn_id, params, raw)
      )

    unless avcs_item["status"] in ["timedOut", "aborted"] do
      Avcs.Turns.update_turn_status(project, turn_id, "in_progress", nil)
    end

    trace_event(project, %{
      scope: "approval",
      event_name: "approval_review_completed",
      thread_id: thread_id,
      turn_id: turn_id,
      item_id: avcs_item["id"],
      codex_thread_id: params["threadId"],
      codex_turn_id: params["turnId"],
      codex_item_id: avcs_item["codex_item_id"],
      status: avcs_item["status"],
      payload: params,
      raw: raw
    })

    payload = approval_payload(thread_id, turn_id, avcs_item)
    Avcs.Events.broadcast("item:updated", payload)
    Avcs.Events.broadcast("approval:resolved", payload)
  end

  defp forward_event(project, thread_id, _turn_id, {:thread_name_updated, params, _raw}) do
    case sync_thread_title(project, thread_id, params["threadName"]) do
      :updated -> broadcast_threads(project)
      :ignored -> :ok
    end
  end

  defp forward_event(project, thread_id, turn_id, {:turn_completed, turn, raw}) do
    trace_event(project, %{
      scope: "turn",
      event_name: "turn_completed",
      thread_id: thread_id,
      turn_id: turn_id,
      codex_thread_id: codex_thread_id_from_raw(raw),
      codex_turn_id: turn["id"],
      status: turn["status"],
      payload: %{turn: turn},
      raw: raw
    })
  end

  defp forward_event(project, thread_id, turn_id, {:error, error, raw}) do
    trace_event(project, %{
      scope: "turn",
      event_name: "turn_error",
      thread_id: thread_id,
      turn_id: turn_id,
      status: "error",
      payload: %{error: error},
      raw: raw
    })

    Avcs.Events.broadcast("error", %{
      thread_id: thread_id,
      turn_id: turn_id,
      message: error["message"] || inspect(error)
    })
  end

  defp forward_event(_project, _thread_id, _turn_id, _event), do: :ok

  defp fail_agent_turn(project, thread_id, turn_id, reason) do
    {:ok, item} = Avcs.Turns.fail_turn(project, turn_id, reason)

    Avcs.Events.broadcast("item:created", %{
      thread_id: thread_id,
      turn_id: turn_id,
      item: item
    })

    Avcs.Events.broadcast("agent:run_completed", %{
      thread_id: thread_id,
      turn_id: turn_id,
      status: "failed"
    })

    Avcs.Events.broadcast("error", %{
      thread_id: thread_id,
      turn_id: turn_id,
      message: to_string(reason),
      scope: "agent"
    })
  end

  defp interrupt_agent_turn(project, thread_id, turn_id) do
    {:ok, _turn} = Avcs.Turns.interrupt_turn(project, turn_id)

    Avcs.Threads.touch(project, thread_id)
    broadcast_threads(project)
    Avcs.Projects.broadcast_projects_updated()

    Avcs.Events.broadcast("agent:run_completed", %{
      thread_id: thread_id,
      turn_id: turn_id,
      status: "interrupted"
    })
  end

  defp ensure_codex_thread_id(project, thread_id, codex_thread_id, context)
       when is_binary(codex_thread_id) and codex_thread_id != "" do
    case Avcs.Threads.get_thread(project, thread_id) do
      {:ok, %{"codex_thread_id" => existing}} when existing in [nil, ""] ->
        persist_codex_thread_id(project, thread_id, codex_thread_id, context)

      {:ok, %{"codex_thread_id" => ^codex_thread_id}} ->
        :ok

      {:ok, %{"codex_thread_id" => existing}} ->
        Logger.warning(
          "Ignoring mismatched Codex thread id #{inspect(codex_thread_id)} for local thread #{thread_id} during #{context}; existing id is #{inspect(existing)}"
        )

        :ok

      {:ok, nil} ->
        report_codex_thread_persist_failure(
          thread_id,
          codex_thread_id,
          context,
          :thread_not_found
        )

        {:error, :thread_not_found}

      {:error, reason} ->
        report_codex_thread_persist_failure(thread_id, codex_thread_id, context, reason)
        {:error, reason}
    end
  end

  defp ensure_codex_thread_id(_project, _thread_id, _codex_thread_id, _context), do: :ok

  defp persist_codex_thread_id(project, thread_id, codex_thread_id, context)
       when is_binary(codex_thread_id) and codex_thread_id != "" do
    case Avcs.Threads.set_codex_thread_id(project, thread_id, codex_thread_id) do
      {:ok, :ok} ->
        :ok

      {:error, reason} ->
        report_codex_thread_persist_failure(thread_id, codex_thread_id, context, reason)
        {:error, reason}
    end
  end

  defp persist_codex_thread_id(_project, thread_id, codex_thread_id, context) do
    reason = "missing Codex thread id during #{context}: #{inspect(codex_thread_id)}"
    report_codex_thread_persist_failure(thread_id, codex_thread_id, context, reason)
    {:error, reason}
  end

  defp report_codex_thread_persist_failure(thread_id, codex_thread_id, context, reason) do
    message =
      "Failed to persist Codex thread id #{inspect(codex_thread_id)} for local thread #{thread_id} during #{context}: #{inspect(reason)}"

    Logger.warning(message)
    Avcs.Events.broadcast("error", %{thread_id: thread_id, message: message, scope: "agent"})
  end

  defp trace_event(project, attrs) do
    case Avcs.Trace.append_event(project, attrs) do
      {:ok, _event} ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to append trace event: #{inspect(reason)}")
        :ok

      _event ->
        :ok
    end
  end

  defp persist_failure_message(reason) do
    "Failed to persist Codex thread id before completing turn: #{inspect(reason)}"
  end

  defp codex_thread_id_from_raw(%{"params" => %{"threadId" => thread_id}})
       when is_binary(thread_id),
       do: thread_id

  defp codex_thread_id_from_raw(%{"threadId" => thread_id}) when is_binary(thread_id),
    do: thread_id

  defp codex_thread_id_from_raw(%{"result" => %{"thread" => %{"id" => thread_id}}})
       when is_binary(thread_id),
       do: thread_id

  defp codex_thread_id_from_raw(_raw), do: nil

  defp approval_payload(thread_id, turn_id, item) do
    %{
      thread_id: thread_id,
      turn_id: turn_id,
      target_item_id: item["payload"]["target_item_id"],
      review_id: item["payload"]["review_id"],
      item: item
    }
  end

  defp forward_codex_approval(thread_id, turn_id, payload) do
    codex_client = Application.get_env(:avcs, :codex_client, Avcs.Agent.CodexAppServerPool)

    if module_exports?(codex_client, :respond_approval, 3) do
      codex_client.respond_approval(thread_id, turn_id, payload)
    else
      :ok
    end
  end

  defp register_image_outputs(
         project,
         thread_id,
         turn_id,
         codex_items,
         before_hashes,
         prompt,
         provider_context
       ) do
    paths =
      codex_items
      |> image_paths_from_items()
      |> Kernel.++(new_output_paths(project, before_hashes))
      |> Enum.map(&Path.expand/1)
      |> Enum.uniq()

    paths
    |> Enum.reduce(MapSet.new(), fn path, seen_asset_ids ->
      case persist_output_image_asset(
             project,
             thread_id,
             turn_id,
             path,
             prompt,
             provider_context
           ) do
        {:ok, asset_id} ->
          MapSet.put(seen_asset_ids, asset_id)

        {:error, reason} ->
          Avcs.Events.broadcast("error", %{message: to_string(reason), scope: "assets"})
          seen_asset_ids
      end
    end)
  end

  defp maybe_put_provider_context(payload, nil), do: payload

  defp maybe_put_provider_context(payload, provider_context),
    do: Map.put(payload, :provider_context, provider_context)

  defp provider_context_for_turn(project, turn_id) do
    case Avcs.Turns.get_turn(project, turn_id) do
      {:ok, %{"data_provider" => data_provider}} ->
        Avcs.Agent.DataProvider.provider_context(data_provider)

      _turn ->
        nil
    end
  end

  defp persist_image_generation_output_on_item_completed(
         project,
         thread_id,
         turn_id,
         item,
         prompt
       ) do
    case item do
      %{"type" => "imageGeneration", "savedPath" => saved_path}
      when is_binary(saved_path) and saved_path != "" ->
        provider_context = provider_context_for_turn(project, turn_id)

        case persist_output_image_asset(
               project,
               thread_id,
               turn_id,
               saved_path,
               prompt,
               provider_context
             ) do
          {:ok, _asset_id} ->
            :ok

          {:error, reason} ->
            Avcs.Events.broadcast("error", %{
              thread_id: thread_id,
              turn_id: turn_id,
              message: to_string(reason),
              scope: "assets"
            })
        end

      _ ->
        :ok
    end
  end

  defp persist_output_image_asset(
         project,
         thread_id,
         turn_id,
         path,
         prompt,
         provider_context
       ) do
    path = Path.expand(path)

    if File.exists?(path) do
      case register_image_path(project, path, thread_id, turn_id, prompt) do
        {:ok, asset} ->
          unless image_asset_item_exists?(project, thread_id, turn_id, asset["id"]) do
            {:ok, item} =
              Avcs.Turns.append_item(project,
                turn_id: turn_id,
                thread_id: thread_id,
                type: "image_asset",
                role: "assistant",
                content: asset["file_name"],
                payload:
                  %{asset_id: asset["id"], source_path: path}
                  |> maybe_put_provider_context(provider_context)
              )

            Avcs.Events.broadcast("item:created", %{
              thread_id: thread_id,
              turn_id: turn_id,
              item: item
            })
          end

          Avcs.Events.broadcast("asset:created", %{asset: asset})
          {:ok, asset["id"]}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, :missing_image_output}
    end
  end

  defp image_paths_from_items(items) do
    items
    |> Enum.flat_map(fn
      %{"type" => "imageGeneration", "savedPath" => path} when is_binary(path) -> [path]
      %{"type" => "imageView", "path" => path} when is_binary(path) -> [path]
      _item -> []
    end)
    |> Enum.filter(&(Avcs.Assets.supported_image?(&1) and File.exists?(&1)))
  end

  defp new_output_paths(project, before_hashes) do
    project
    |> Avcs.Projects.output_dir()
    |> Path.join("**/*")
    |> Path.wildcard()
    |> Enum.filter(&(File.regular?(&1) and Avcs.Assets.supported_image?(&1)))
    |> Enum.reject(&(file_hash(&1) in before_hashes))
  end

  defp register_image_path(project, path, thread_id, turn_id, prompt) do
    opts = [source: "generated", thread_id: thread_id, turn_id: turn_id, prompt: prompt]

    case Avcs.Projects.relative_to_project(project, path) do
      {:ok, _relative_path} -> Avcs.Assets.upsert_asset(project, path, opts)
      {:error, :outside_project} -> Avcs.Assets.import_image(project, path, opts)
    end
  end

  defp image_asset_item_exists?(project, thread_id, turn_id, asset_id) do
    case Avcs.Turns.list_items(project, thread_id) do
      {:ok, items} ->
        Enum.any?(items, fn item ->
          item["turn_id"] == turn_id and item["type"] == "image_asset" and
            get_in(item, ["payload", "asset_id"]) == asset_id
        end)

      {:error, _reason} ->
        false
    end
  end

  defp broadcast_thread_items(project, thread_id) do
    case Avcs.Turns.list_items(project, thread_id) do
      {:ok, items} -> Avcs.Events.broadcast("thread:items", %{thread_id: thread_id, items: items})
      {:error, _reason} -> :ok
    end
  end

  defp broadcast_lists(project, _thread_id) do
    case Avcs.Threads.list_threads(project) do
      {:ok, threads} ->
        Avcs.Events.broadcast("threads:updated", %{
          project_id: project["id"],
          items: threads,
          current_thread_id: Avcs.Session.current_thread_id()
        })

      {:error, _reason} ->
        :ok
    end

    case Avcs.Assets.list_assets(project) do
      {:ok, assets} -> Avcs.Events.broadcast("assets:updated", %{items: assets})
      {:error, _reason} -> :ok
    end

    case Avcs.Board.list_items(project) do
      {:ok, board_items} -> Avcs.Events.broadcast("board:items", %{items: board_items})
      {:error, _reason} -> :ok
    end
  end

  defp broadcast_threads(project) do
    {:ok, threads} = Avcs.Threads.list_threads(project)

    Avcs.Events.broadcast("threads:updated", %{
      project_id: project["id"],
      items: threads,
      current_thread_id: Avcs.Session.current_thread_id()
    })
  end

  defp sync_thread_title(project, thread_id, title) when is_binary(title) do
    case String.trim(title) do
      "" ->
        :ignored

      title ->
        {:ok, _thread} = Avcs.Threads.rename_thread(project, thread_id, title)
        :updated
    end
  end

  defp sync_thread_title(_project, _thread_id, _title), do: :ignored

  defp repairable_thread(_project, nil), do: {:ok, nil}

  defp repairable_thread(_project, %{"codex_thread_id" => codex_thread_id} = thread)
       when is_binary(codex_thread_id) and codex_thread_id != "" do
    {:ok, thread}
  end

  defp repairable_thread(project, thread) do
    with {:ok, codex_thread_id} <- recover_codex_thread_id(project, thread),
         :ok <- persist_codex_thread_id(project, thread["id"], codex_thread_id, :repair_recovered) do
      {:ok, %{thread | "codex_thread_id" => codex_thread_id}}
    else
      {:error, :not_found} -> {:error, :codex_thread_id_missing}
      {:error, reason} -> {:error, reason}
    end
  end

  defp recover_codex_thread_id(project, thread) do
    with {:ok, codex_item_ids} <- repair_codex_item_ids(project, thread["id"]),
         [_first | _rest] <- codex_item_ids,
         {:ok, codex_thread_id} <- find_codex_session_thread_id(project, codex_item_ids) do
      {:ok, codex_thread_id}
    else
      [] -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp repair_codex_item_ids(project, thread_id) do
    with {:ok, items} <- Avcs.Turns.list_items(project, thread_id) do
      codex_item_ids =
        items
        |> Enum.map(& &1["codex_item_id"])
        |> Enum.filter(&(is_binary(&1) and &1 != ""))
        |> Enum.uniq()

      {:ok, codex_item_ids}
    end
  end

  defp find_codex_session_thread_id(project, codex_item_ids) do
    project_path = project |> Avcs.Projects.folder_path() |> Path.expand()

    codex_session_files()
    |> Enum.find_value(fn path ->
      with %{"id" => session_id, "cwd" => cwd} when is_binary(session_id) and is_binary(cwd) <-
             codex_session_meta(path),
           true <- Path.expand(cwd) == project_path,
           true <- file_contains_any?(path, codex_item_ids) do
        session_id
      else
        _ -> nil
      end
    end)
    |> case do
      nil -> {:error, :not_found}
      session_id -> {:ok, session_id}
    end
  end

  defp codex_session_files do
    codex_home = Application.get_env(:avcs, :codex_home) || System.get_env("CODEX_HOME")

    codex_home =
      if is_binary(codex_home) and codex_home != "" do
        codex_home
      else
        Path.join(System.user_home!(), ".codex")
      end

    [
      Path.join([codex_home, "sessions", "**", "*.jsonl"]),
      Path.join([codex_home, "archived_sessions", "*.jsonl"])
    ]
    |> Enum.flat_map(&Path.wildcard/1)
    |> Enum.sort(:desc)
  end

  defp codex_session_meta(path) do
    path
    |> File.stream!([], :line)
    |> Stream.take(20)
    |> Enum.find_value(fn line ->
      case Jason.decode(line) do
        {:ok, %{"type" => "session_meta", "payload" => payload}} -> payload
        _other -> nil
      end
    end)
  rescue
    _error -> nil
  end

  defp file_contains_any?(path, needles) do
    path
    |> File.stream!([], :line)
    |> Enum.any?(fn line ->
      Enum.any?(needles, &String.contains?(line, &1))
    end)
  rescue
    _error -> false
  end

  defp read_codex_thread(project, thread_id, codex_thread_id) do
    codex_client = Application.get_env(:avcs, :codex_client, Avcs.Agent.CodexAppServerPool)

    if module_exports?(codex_client, :read_thread, 2) do
      codex_client.read_thread(codex_thread_id,
        include_turns: true,
        project: project,
        avcs_thread_id: thread_id
      )
    else
      {:error, :thread_read_unsupported}
    end
  end

  defp reconcile_codex_thread(project, local_thread, codex_thread) do
    codex_turns = codex_thread["turns"] || []
    {:ok, local_turns} = Avcs.Turns.list_turns(project, local_thread["id"])

    {matched_turns, stats} =
      reconcile_codex_turns(project, local_thread, local_turns, codex_turns)

    sync_thread_title(
      project,
      local_thread["id"],
      codex_thread["name"] || codex_thread["preview"]
    )

    Avcs.Threads.touch(project, local_thread["id"])

    {:ok,
     %{
       codex_thread_id: codex_thread["id"],
       codex_turns: length(codex_turns),
       matched_turns: matched_turns,
       synced_items: stats.synced_items,
       imported_images: stats.imported_images
     }}
  end

  defp reconcile_codex_turns(project, local_thread, local_turns, codex_turns) do
    initial_stats = %{synced_items: 0, imported_images: 0}

    {matched_count, stats, _used_turn_ids} =
      Enum.reduce(codex_turns, {0, initial_stats, MapSet.new()}, fn codex_turn,
                                                                    {matched_count, stats,
                                                                     used_turn_ids} ->
        available_turns = Enum.reject(local_turns, &MapSet.member?(used_turn_ids, &1["id"]))

        case match_local_turn(available_turns, codex_turn) do
          nil ->
            {matched_count, stats, used_turn_ids}

          local_turn ->
            before_assets = asset_count(project)
            codex_items = codex_turn["items"] || []
            sync_codex_turn(project, local_thread["id"], local_turn, codex_turn, codex_items)
            after_assets = asset_count(project)

            {matched_count + 1,
             %{
               synced_items: stats.synced_items + length(codex_items),
               imported_images: stats.imported_images + max(after_assets - before_assets, 0)
             }, MapSet.put(used_turn_ids, local_turn["id"])}
        end
      end)

    {matched_count, stats}
  end

  defp sync_codex_turn(project, thread_id, local_turn, codex_turn, codex_items) do
    codex_turn_id = codex_turn["id"]

    if is_binary(codex_turn_id) and codex_turn_id != "" do
      {:ok, _turn} =
        Avcs.Turns.update_turn_status(
          project,
          local_turn["id"],
          local_turn_status(codex_turn),
          codex_turn_id,
          turn_error_message(codex_turn)
        )
    end

    codex_items
    |> Enum.reject(&(&1["type"] == "userMessage"))
    |> Enum.each(&sync_codex_item(project, thread_id, local_turn["id"], &1))

    register_image_outputs(
      project,
      thread_id,
      local_turn["id"],
      codex_items,
      output_hashes(project),
      local_turn["user_text"] || "",
      Avcs.Agent.DataProvider.provider_context(local_turn["data_provider"], codex_items)
    )
  end

  defp sync_codex_item(project, thread_id, turn_id, %{"type" => "agentMessage"} = item) do
    text = item["text"] || ""

    if String.trim(text) != "" and
         not assistant_message_exists?(project, thread_id, turn_id, item) do
      {:ok, avcs_item} =
        Avcs.Turns.upsert_codex_item(project,
          turn_id: turn_id,
          thread_id: thread_id,
          codex_item_id: item["id"],
          type: "assistant_message",
          role: "assistant",
          content: text,
          status: "completed",
          payload: %{codex_item: persistable_codex_item(item), recovered: true}
        )

      Avcs.Events.broadcast("item:updated", %{
        thread_id: thread_id,
        turn_id: turn_id,
        item: avcs_item
      })
    end
  end

  defp sync_codex_item(project, thread_id, turn_id, item) do
    if tool_item?(item) do
      status = tool_status(item)

      {:ok, avcs_item} =
        Avcs.Turns.upsert_codex_item(project,
          turn_id: turn_id,
          thread_id: thread_id,
          codex_item_id: item["id"],
          type: if(status == "running", do: "tool_call", else: "tool_result"),
          role: "tool",
          content: tool_summary(item),
          status: status,
          payload: %{
            codex_item: persistable_codex_item(item),
            tool_name: tool_name(item),
            recovered: true
          }
        )

      Avcs.Events.broadcast("item:updated", %{
        thread_id: thread_id,
        turn_id: turn_id,
        item: avcs_item
      })
    end
  end

  defp assistant_message_exists?(project, thread_id, turn_id, item) do
    case Avcs.Turns.list_items(project, thread_id) do
      {:ok, items} ->
        Enum.any?(items, fn local_item ->
          local_item["turn_id"] == turn_id and local_item["type"] == "assistant_message" and
            (local_item["codex_item_id"] == item["id"] or local_item["content"] == item["text"])
        end)

      {:error, _reason} ->
        false
    end
  end

  defp match_local_turn(local_turns, %{"id" => codex_turn_id} = codex_turn) do
    Enum.find(local_turns, &(&1["codex_turn_id"] == codex_turn_id)) ||
      match_local_turn_by_user_text(local_turns, codex_turn) ||
      match_single_unlinked_turn(local_turns)
  end

  defp match_local_turn(local_turns, codex_turn) do
    match_local_turn_by_user_text(local_turns, codex_turn) ||
      match_single_unlinked_turn(local_turns)
  end

  defp match_local_turn_by_user_text(local_turns, codex_turn) do
    codex_text = codex_turn_user_text(codex_turn)

    if codex_text do
      Enum.find(local_turns, fn turn ->
        is_nil(turn["codex_turn_id"]) and normalized_text(turn["user_text"]) == codex_text
      end)
    end
  end

  defp match_single_unlinked_turn(local_turns) do
    case Enum.filter(local_turns, &is_nil(&1["codex_turn_id"])) do
      [turn] -> turn
      _turns -> nil
    end
  end

  defp codex_turn_user_text(%{"items" => items}) when is_list(items) do
    items
    |> Enum.find(&(&1["type"] == "userMessage"))
    |> user_message_text()
    |> normalized_text()
    |> case do
      "" -> nil
      text -> text
    end
  end

  defp codex_turn_user_text(_turn), do: nil

  defp user_message_text(%{"content" => content}) when is_list(content) do
    content
    |> Enum.map(fn
      %{"type" => "text", "text" => text} -> text
      %{"text" => text} -> text
      _part -> ""
    end)
    |> Enum.join(" ")
  end

  defp user_message_text(_item), do: ""

  defp normalized_text(nil), do: ""

  defp normalized_text(text) do
    text
    |> to_string()
    |> String.trim()
    |> String.replace(~r/\s+/u, " ")
  end

  defp local_turn_status(%{"status" => "completed"}), do: "completed"
  defp local_turn_status(%{"status" => "failed"}), do: "failed"
  defp local_turn_status(%{"status" => "interrupted"}), do: "interrupted"
  defp local_turn_status(%{"status" => "inProgress"}), do: "in_progress"
  defp local_turn_status(%{"status" => "in_progress"}), do: "in_progress"
  defp local_turn_status(_turn), do: "in_progress"

  defp turn_error_message(%{"error" => %{"message" => message}}) when is_binary(message),
    do: message

  defp turn_error_message(%{"status" => "interrupted"}), do: nil
  defp turn_error_message(_turn), do: nil

  defp asset_count(project) do
    case Avcs.Assets.list_assets(project) do
      {:ok, assets} -> length(assets)
      {:error, _reason} -> 0
    end
  end

  defp run_codex_turn(
         codex_client,
         project,
         codex_thread_id,
         text,
         reference_paths,
         on_event,
         settings
       ) do
    cond do
      module_exports?(codex_client, :run_turn, 8) ->
        codex_client.run_turn(
          project,
          settings[:avcs_thread_id],
          settings[:avcs_turn_id],
          codex_thread_id,
          text,
          reference_paths,
          on_event,
          settings
        )

      module_exports?(codex_client, :run_turn, 6) ->
        codex_client.run_turn(project, codex_thread_id, text, reference_paths, on_event, settings)

      true ->
        codex_client.run_turn(project, codex_thread_id, text, reference_paths, on_event)
    end
  end

  defp pool_managed_client?(codex_client) do
    module_exports?(codex_client, :active_turn, 2) and
      module_exports?(codex_client, :steer_turn, 5) and
      module_exports?(codex_client, :run_turn, 8)
  end

  defp module_exports?(module, function, arity) when is_atom(module) do
    Code.ensure_loaded?(module) and function_exported?(module, function, arity)
  end

  defp module_exports?(_module, _function, _arity), do: false

  defp tool_item?(%{"type" => type}) do
    type in [
      "commandExecution",
      "mcpToolCall",
      "dynamicToolCall",
      "webSearch",
      "imageGeneration",
      "imageView",
      "fileChange"
    ]
  end

  defp tool_item?(_item), do: false

  defp tool_name(%{"type" => "commandExecution"}), do: "command"

  defp tool_name(%{"type" => "mcpToolCall", "server" => server, "tool" => tool}),
    do: "#{server}/#{tool}"

  defp tool_name(%{"type" => "dynamicToolCall", "name" => name}) when is_binary(name), do: name
  defp tool_name(%{"type" => "webSearch"}), do: "web search"
  defp tool_name(%{"type" => "imageGeneration"}), do: "image generation"
  defp tool_name(%{"type" => "imageView"}), do: "image view"
  defp tool_name(%{"type" => "fileChange"}), do: "file change"
  defp tool_name(%{"type" => type}) when is_binary(type), do: type
  defp tool_name(_item), do: "tool"

  defp tool_status(%{"status" => status}) when status in ["failed", "cancelled"], do: status

  defp tool_status(%{"status" => status}) when status in ["in_progress", "inProgress"],
    do: "running"

  defp tool_status(%{"status" => "running"}), do: "running"
  defp tool_status(%{"status" => "completed"}), do: "completed"
  defp tool_status(%{"error" => error}) when not is_nil(error), do: "failed"
  defp tool_status(_item), do: "completed"

  defp tool_summary(%{"type" => "commandExecution"} = item) do
    item["command"] || item["cmd"] || item["text"] || "Command"
  end

  defp tool_summary(%{"type" => "mcpToolCall"} = item) do
    [item["server"], item["tool"]]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" / ")
    |> case do
      "" -> "MCP tool"
      summary -> summary
    end
  end

  defp tool_summary(%{"type" => "dynamicToolCall"} = item) do
    item["name"] || "Dynamic tool"
  end

  defp tool_summary(%{"type" => "webSearch"} = item) do
    item["query"] || item["text"] || "Web search"
  end

  defp tool_summary(%{"type" => "imageGeneration"} = item) do
    item["prompt"] || item["revisedPrompt"] || item["savedPath"] || "Image generation"
  end

  defp tool_summary(%{"type" => "imageView"} = item) do
    item["path"] || "Image view"
  end

  defp tool_summary(%{"type" => "fileChange"} = item) do
    item["path"] || item["summary"] || "File change"
  end

  defp tool_summary(item), do: tool_name(item)

  defp persistable_codex_item(%{"type" => "imageGeneration", "result" => result} = item)
       when is_binary(result) and result != "" do
    item
    |> Map.delete("result")
    |> Map.put("result_omitted", true)
    |> Map.put("result_size_bytes", byte_size(result))
  end

  defp persistable_codex_item(item), do: item

  defp output_hashes(project) do
    Avcs.Projects.output_dir(project)
    |> Path.join("**/*")
    |> Path.wildcard()
    |> Enum.filter(&File.regular?/1)
    |> MapSet.new(&file_hash/1)
  end

  defp file_hash(path) do
    case File.read(path) do
      {:ok, binary} -> :crypto.hash(:sha256, binary) |> Base.encode16(case: :lower)
      {:error, _reason} -> nil
    end
  end
end
