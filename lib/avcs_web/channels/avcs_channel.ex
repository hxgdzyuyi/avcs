defmodule AvcsWeb.AvcsChannel do
  use AvcsWeb, :channel

  @impl true
  def join("avcs:lobby", _payload, socket) do
    _restore_result = Avcs.Projects.restore_last_opened_project()
    {:ok, projects} = Avcs.Projects.list_projects()
    {:ok, %{project: Avcs.Projects.current_project(), projects: projects}, socket}
  end

  @impl true
  def handle_in("project:current", _payload, socket) do
    reply_ok(%{project: Avcs.Projects.current_project()}, socket)
  end

  def handle_in("projects:list", _payload, socket) do
    case Avcs.Projects.list_projects() do
      {:ok, projects} -> reply_ok(%{items: projects}, socket)
      {:error, reason} -> reply_error("projects_list_failed", to_string(reason), socket)
    end
  end

  def handle_in("site_settings:get", _payload, socket) do
    case Avcs.SiteSettings.list_settings() do
      {:ok, items} ->
        reply_ok(%{items: items, settings: Map.new(items, &{&1.key, &1.value})}, socket)

      {:error, reason} ->
        reply_site_settings_error(reason, socket)
    end
  end

  def handle_in("site_settings:update", payload, socket) do
    case Avcs.SiteSettings.update_settings(payload["settings"] || %{}) do
      {:ok, data} ->
        Avcs.Events.broadcast("site_settings:updated", data)
        reply_ok(data, socket)

      {:error, reason} ->
        reply_site_settings_error(reason, socket)
    end
  end

  def handle_in("site_settings:reset", payload, socket) do
    case Avcs.SiteSettings.reset_settings(payload["keys"] || []) do
      {:ok, data} ->
        Avcs.Events.broadcast("site_settings:updated", data)
        reply_ok(data, socket)

      {:error, reason} ->
        reply_site_settings_error(reason, socket)
    end
  end

  def handle_in("project:select", %{"id" => id}, socket) do
    case Avcs.Projects.select_project(id) do
      {:ok, project} ->
        broadcast_threads(project)
        reply_ok(%{project: project}, socket)

      {:error, reason} ->
        reply_error("project_select_failed", to_string(reason), socket)
    end
  end

  def handle_in("project:rename", %{"id" => id, "name" => name}, socket) do
    case Avcs.Projects.rename_project(id, name) do
      {:ok, project} ->
        reply_ok(project, socket)

      {:error, :project_not_found} ->
        reply_error("project_not_found", "Project was not found", socket)

      {:error, :invalid_project_name} ->
        reply_error("invalid_project_name", "Project name is invalid", socket)

      {:error, reason} ->
        reply_error("project_rename_failed", to_string(reason), socket)
    end
  end

  def handle_in("project:rename", _payload, socket) do
    reply_error("invalid_project_name", "Project name is invalid", socket)
  end

  def handle_in("project:archive", %{"id" => id}, socket) do
    case Avcs.Projects.archive_project(id) do
      {:ok, archived_project} ->
        reply_ok(
          %{
            archived_project_id: archived_project["id"],
            project: Avcs.Projects.current_project()
          },
          socket
        )

      {:error, reason} ->
        reply_error("project_archive_failed", to_string(reason), socket)
    end
  end

  def handle_in("project:delete", %{"id" => id}, socket) do
    case Avcs.Projects.delete_project_reference(id) do
      {:ok, deleted_project} ->
        reply_ok(
          %{deleted_project_id: deleted_project["id"], project: Avcs.Projects.current_project()},
          socket
        )

      {:error, reason} ->
        reply_error("project_delete_failed", to_string(reason), socket)
    end
  end

  def handle_in("project:reorder", %{"ordered_ids" => ordered_ids}, socket) do
    case Avcs.Projects.reorder_projects(ordered_ids) do
      {:ok, projects} ->
        Avcs.Projects.broadcast_projects_updated()
        reply_ok(%{items: projects}, socket)

      {:error, :project_not_found} ->
        reply_error("project_not_found", "Some project was not found", socket)

      {:error, :project_unavailable} ->
        reply_error("project_unavailable", "Some project folder is unavailable", socket)

      {:error, :invalid_reorder_payload} ->
        reply_error("invalid_reorder_payload", "Invalid reorder payload", socket)

      {:error, reason} ->
        reply_error("project_reorder_failed", to_string(reason), socket)
    end
  end

  def handle_in("project:reorder", _payload, socket) do
    reply_error("invalid_reorder_payload", "Invalid reorder payload", socket)
  end

  def handle_in("threads:list", %{"project_id" => project_id}, socket) do
    with_project_by_id(project_id, socket, fn project ->
      {:ok, threads} = Avcs.Threads.list_threads(project)
      reply_ok(%{items: threads}, socket)
    end)
  end

  def handle_in("threads:list", _payload, socket) do
    with_project(socket, fn project ->
      {:ok, threads} = Avcs.Threads.list_threads(project)
      reply_ok(%{items: threads}, socket)
    end)
  end

  def handle_in("threads:archive_all", %{"project_id" => project_id}, socket) do
    with_project_by_id(project_id, socket, fn project ->
      {:ok, result} = Avcs.Threads.archive_all_threads(project)

      if current_project?(project) do
        :ok = Avcs.Session.set_current_thread_id(nil)
      end

      broadcast_threads(project)
      Avcs.Projects.broadcast_projects_updated()

      reply_ok(
        Map.merge(result, %{
          project_id: project["id"],
          current_thread_id: Avcs.Session.current_thread_id()
        }),
        socket
      )
    end)
  end

  def handle_in("thread:create", payload, socket) do
    with_project(socket, fn project ->
      {:ok, thread} = Avcs.Threads.create_thread(project, payload["title"] || "Untitled thread")
      :ok = Avcs.Session.set_current_thread_id(thread["id"])
      broadcast_threads(project)
      Avcs.Projects.broadcast_projects_updated()
      reply_ok(thread, socket)
    end)
  end

  def handle_in("thread:rename", %{"id" => id, "title" => title}, socket) do
    with_project(socket, fn project ->
      {:ok, thread} = Avcs.Threads.rename_thread(project, id, title)
      broadcast_threads(project)
      Avcs.Projects.broadcast_projects_updated()
      reply_ok(thread, socket)
    end)
  end

  def handle_in(
        "thread:reorder",
        %{"project_id" => project_id, "ordered_ids" => ordered_ids},
        socket
      ) do
    with_project_by_id(project_id, socket, fn project ->
      case Avcs.Threads.reorder_threads(project, ordered_ids) do
        {:ok, threads} ->
          broadcast_threads(project)
          reply_ok(%{project_id: project["id"], items: threads}, socket)

        {:error, :thread_not_found} ->
          reply_error("thread_not_found", "Some thread was not found", socket)

        {:error, :invalid_reorder_payload} ->
          reply_error("invalid_reorder_payload", "Invalid reorder payload", socket)

        {:error, reason} ->
          reply_error("thread_reorder_failed", to_string(reason), socket)
      end
    end)
  end

  def handle_in("thread:reorder", payload, socket) do
    if is_map(payload) do
      with_project_by_id(payload["project_id"], socket, fn project ->
        case Avcs.Threads.reorder_threads(project, payload["ordered_ids"]) do
          {:ok, threads} ->
            broadcast_threads(project)
            reply_ok(%{project_id: project["id"], items: threads}, socket)

          {:error, :thread_not_found} ->
            reply_error("thread_not_found", "Some thread was not found", socket)

          {:error, :invalid_reorder_payload} ->
            reply_error("invalid_reorder_payload", "Invalid reorder payload", socket)

          {:error, reason} ->
            reply_error("thread_reorder_failed", to_string(reason), socket)
        end
      end)
    else
      reply_error("invalid_reorder_payload", "Invalid reorder payload", socket)
    end
  end

  def handle_in("thread:delete", %{"id" => id}, socket) do
    with_project(socket, fn project ->
      current_thread_id = Avcs.Session.current_thread_id()
      {:ok, :ok} = Avcs.Threads.archive_thread(project, id)
      {:ok, threads} = Avcs.Threads.list_threads(project)
      next_thread_id = next_current_thread_id(current_thread_id, id, threads)
      :ok = Avcs.Session.set_current_thread_id(next_thread_id)
      broadcast_threads(project)
      Avcs.Projects.broadcast_projects_updated()
      reply_ok(%{current_thread_id: next_thread_id}, socket)
    end)
  end

  def handle_in("thread:select", %{"id" => id}, socket) do
    with_project(socket, fn _project ->
      :ok = Avcs.Session.set_current_thread_id(id)
      reply_ok(%{current_thread_id: id}, socket)
    end)
  end

  def handle_in("thread:settings:update", %{"id" => id} = payload, socket) do
    with_project(socket, fn project ->
      case Avcs.Threads.update_settings(project, id, payload) do
        {:ok, thread} ->
          broadcast_threads(project)
          reply_ok(thread, socket)

        {:error, reason} ->
          reply_error("thread_settings_update_failed", to_string(reason), socket)
      end
    end)
  end

  def handle_in("thread:items:list", payload, socket) do
    with_project(socket, fn project ->
      thread_id = payload["thread_id"] || Avcs.Session.current_thread_id()
      {:ok, items} = Avcs.Turns.list_items(project, thread_id)
      reply_ok(%{thread_id: thread_id, items: items}, socket)
    end)
  end

  def handle_in("thread:items:page", payload, socket) do
    with_project(socket, fn project ->
      thread_id = payload["thread_id"] || Avcs.Session.current_thread_id()

      case Avcs.Turns.list_item_page(project, thread_id, payload) do
        {:ok, result} ->
          reply_ok(Map.put(result, :request_id, payload["request_id"]), socket)

        {:error, :invalid_page_cursor} ->
          reply_error("invalid_page_cursor", "Message page cursor is invalid", socket)

        {:error, :turn_anchor_not_found} ->
          reply_error("turn_anchor_not_found", "Anchor turn was not found", socket)

        {:error, reason} ->
          reply_error("thread_items_page_failed", to_string(reason), socket)
      end
    end)
  end

  def handle_in("trace:events:list", payload, socket) do
    with_project(socket, fn project ->
      thread_id = payload["thread_id"] || Avcs.Session.current_thread_id()
      opts = [turn_id: payload["turn_id"]]

      if is_binary(thread_id) and thread_id != "" do
        case Avcs.Trace.list_events(project, thread_id, opts) do
          {:ok, events} -> reply_ok(%{thread_id: thread_id, items: events}, socket)
          {:error, reason} -> reply_error("trace_events_list_failed", to_string(reason), socket)
        end
      else
        reply_ok(%{thread_id: thread_id, items: []}, socket)
      end
    end)
  end

  def handle_in("thread:repair", payload, socket) do
    with_project(socket, fn project ->
      thread_id = payload["thread_id"] || Avcs.Session.current_thread_id()

      case repair_thread(project, thread_id) do
        {:ok, repair} ->
          {:ok, assets} = Avcs.Assets.list_assets(project)
          {:ok, board_items} = Avcs.Board.list_items(project)
          {:ok, threads} = Avcs.Threads.list_threads(project)

          reply_ok(
            %{
              thread_id: thread_id,
              repair: repair,
              assets: assets,
              board_items: board_items,
              threads: threads
            },
            socket
          )

        {:error, :thread_not_found} ->
          reply_error("thread_not_found", "Thread was not found", socket)

        {:error, :codex_thread_id_missing} ->
          reply_error(
            "thread_repair_missing_codex_thread",
            "This thread has no Codex thread id to read from",
            socket
          )

        {:error, :thread_read_unsupported} ->
          reply_error(
            "thread_repair_unsupported",
            "Current Codex client cannot read Codex threads",
            socket
          )

        {:error, reason} ->
          reply_error("thread_repair_failed", to_string(reason), socket)
      end
    end)
  end

  def handle_in("message:send", payload, socket) do
    with_project(socket, fn project ->
      thread_id = payload["thread_id"] || Avcs.Session.current_thread_id()
      text = String.trim(payload["text"] || "")
      turn_settings = Avcs.Threads.clean_settings(payload)

      case message_assets_and_settings(project, payload, turn_settings) do
        {:ok, asset_ids, turn_settings} ->
          if text == "" and asset_ids == [] do
            reply_error("empty_message", "Message text or image reference is required", socket)
          else
            {:ok, thread} = Avcs.Threads.update_settings(project, thread_id, turn_settings)
            {:ok, thread} = Avcs.Threads.maybe_title_from_message(project, thread, text)

            runner = Application.get_env(:avcs, :agent_runner, Avcs.Agent.Runner)

            case submit_runner(runner, project, thread_id, text, asset_ids, turn_settings) do
              {:ok, created} ->
                reply_ok(Map.put(created, "thread", thread), socket)

              {:error, reason} ->
                reply_error("message_send_failed", to_string(reason), socket)
            end
          end

        {:error, code, message} ->
          reply_error(code, message, socket)
      end
    end)
  end

  def handle_in("message:edit_rerun", %{"item_id" => item_id, "content" => content}, socket) do
    with_project(socket, fn project ->
      runner = Application.get_env(:avcs, :agent_runner, Avcs.Agent.Runner)

      case rerun_runner(runner, project, item_id, content) do
        {:ok, result} ->
          reply_ok(result, socket)

        {:error, :item_not_found} ->
          reply_error("item_not_found", "Message item was not found", socket)

        {:error, :message_edit_unsupported} ->
          reply_error(
            "message_edit_unsupported",
            "This message cannot be edited and rerun",
            socket
          )

        {:error, :message_edit_conflict} ->
          reply_error(
            "message_edit_conflict",
            "Stop or wait for the current Agent run before editing history",
            socket
          )

        {:error, :empty_message} ->
          reply_error("empty_message", "Message text is required", socket)

        {:error, reason} ->
          reply_error("message_edit_rerun_failed", to_string(reason), socket)
      end
    end)
  end

  def handle_in("message:edit_rerun", _payload, socket) do
    reply_error("message_edit_rerun_failed", "Message edit payload is invalid", socket)
  end

  def handle_in("turn:stop", payload, socket) do
    with_project(socket, fn project ->
      thread_id = payload["thread_id"] || Avcs.Session.current_thread_id()
      turn_id = payload["turn_id"]

      with {:ok, thread_id} <- require_thread_id(thread_id),
           {:ok, _thread} <- require_thread(project, thread_id) do
        runner = Application.get_env(:avcs, :agent_runner, Avcs.Agent.Runner)

        case stop_runner(runner, project, thread_id, turn_id) do
          {:ok, result} ->
            reply_ok(
              %{
                thread_id: thread_id,
                turn_id: result[:turn_id] || result["turn_id"] || turn_id,
                status: result[:status] || result["status"] || "stopping"
              },
              socket
            )

          {:error, :not_running} ->
            reply_error("turn_not_running", "Turn is not running", socket)

          {:error, :interrupt_unsupported} ->
            reply_error("turn_stop_unsupported", "Stopping turns is not supported", socket)

          {:error, reason} ->
            reply_error("turn_stop_failed", to_string(reason), socket)
        end
      else
        {:error, :thread_required} ->
          reply_error("thread_required", "Thread id is required", socket)

        {:error, :thread_not_found} ->
          reply_error("thread_not_found", "Thread was not found", socket)
      end
    end)
  end

  def handle_in("item:update", %{"id" => id, "content" => content}, socket) do
    with_project(socket, fn project ->
      case Avcs.Turns.update_item(project, id, %{
             content: to_string(content),
             payload: %{"edited_at" => Avcs.Time.now_iso()}
           }) do
        {:ok, item} ->
          payload = %{
            thread_id: item["thread_id"],
            turn_id: item["turn_id"],
            item: item
          }

          Avcs.Events.broadcast("item:updated", payload)
          reply_ok(%{item: item}, socket)

        {:error, :not_found} ->
          reply_error("item_not_found", "Message item was not found", socket)

        {:error, reason} ->
          reply_error("item_update_failed", to_string(reason), socket)
      end
    end)
  end

  def handle_in("models:list", _payload, socket) do
    socket_ref = socket_ref(socket)

    Task.Supervisor.start_child(Avcs.Agent.TaskSupervisor, fn ->
      reply(socket_ref, models_list_reply())
    end)

    {:noreply, socket}
  end

  def handle_in("approval:respond", payload, socket) do
    with_project(socket, fn project ->
      thread_id = payload["thread_id"] || Avcs.Session.current_thread_id()
      turn_id = payload["turn_id"]
      review_id = payload["review_id"]
      decision = clean_decision(payload["decision"])

      with {:ok, _decision} <- require_decision(decision),
           {:ok, item} <- Avcs.Turns.get_approval_item(project, thread_id, turn_id, review_id),
           {:ok, updated_item} <- apply_approval_response(project, item, decision) do
        response_payload = %{
          thread_id: thread_id,
          turn_id: turn_id,
          target_item_id: updated_item["payload"]["target_item_id"],
          review_id: review_id,
          item: updated_item
        }

        Avcs.Events.broadcast("item:updated", response_payload)
        Avcs.Events.broadcast("approval:resolved", response_payload)
        reply_ok(%{item: updated_item}, socket)
      else
        {:error, :not_found} ->
          reply_error("approval_not_found", "Approval request was not found", socket)

        {:error, :not_running} ->
          reply_error("approval_run_not_active", "Agent run is no longer active", socket)

        {:error, :missing_event} ->
          reply_error(
            "approval_event_missing",
            "Approval request event payload is missing",
            socket
          )

        {:error, :invalid_decision} ->
          reply_error(
            "approval_invalid_decision",
            "Approval decision must be approve or deny",
            socket
          )

        {:error, reason} ->
          reply_error("approval_response_failed", to_string(reason), socket)
      end
    end)
  end

  def handle_in("assets:list", _payload, socket) do
    with_project(socket, fn project ->
      {:ok, assets} = Avcs.Assets.list_assets(project)
      reply_ok(%{items: assets}, socket)
    end)
  end

  def handle_in("assets:reference", payload, socket) do
    reply_ok(%{asset_ids: payload["asset_ids"] || []}, socket)
  end

  def handle_in("assets:select", payload, socket) do
    reply_ok(%{asset_id: payload["asset_id"]}, socket)
  end

  def handle_in("board:items:list", _payload, socket) do
    with_project(socket, fn project ->
      {:ok, items} = Avcs.Board.list_items(project)
      reply_ok(%{items: items}, socket)
    end)
  end

  def handle_in("board:item:move", %{"id" => id, "x" => x, "y" => y}, socket) do
    with_project(socket, fn project ->
      case Avcs.Board.move_item(project, id, x, y) do
        {:ok, item} ->
          Avcs.Events.broadcast("board:item:updated", %{item: item})
          reply_ok(item, socket)

        {:error, :board_item_not_found} ->
          reply_error("board_item_not_found", "Board item was not found", socket)

        {:error, :invalid_board_item_update} ->
          reply_error("invalid_board_item_update", "Board item update is invalid", socket)

        {:error, reason} ->
          reply_error("board_item_move_failed", to_string(reason), socket)
      end
    end)
  end

  def handle_in(
        "board:item:resize",
        %{"id" => id, "display_width" => width, "display_height" => height},
        socket
      ) do
    with_project(socket, fn project ->
      case Avcs.Board.resize_item(project, id, width, height) do
        {:ok, item} ->
          Avcs.Events.broadcast("board:item:updated", %{item: item})
          reply_ok(item, socket)

        {:error, :board_item_not_found} ->
          reply_error("board_item_not_found", "Board item was not found", socket)

        {:error, :invalid_board_item_update} ->
          reply_error("invalid_board_item_update", "Board item update is invalid", socket)

        {:error, reason} ->
          reply_error("board_item_resize_failed", to_string(reason), socket)
      end
    end)
  end

  def handle_in("board:items:update", %{"items" => updates}, socket) do
    with_project(socket, fn project ->
      case Avcs.Board.update_items(project, updates) do
        {:ok, items} ->
          updated_ids = MapSet.new(updates, & &1["id"])
          updated_items = Enum.filter(items, &MapSet.member?(updated_ids, &1["id"]))

          Enum.each(updated_items, fn item ->
            Avcs.Events.broadcast("board:item:updated", %{item: item})
          end)

          if length(updated_items) > 50 do
            Avcs.Events.broadcast("board:items", %{items: items})
          end

          reply_ok(%{items: updated_items}, socket)

        {:error, :board_item_not_found} ->
          reply_error("board_item_not_found", "Board item was not found", socket)

        {:error, :invalid_board_item_update} ->
          reply_error("invalid_board_item_update", "Board item update is invalid", socket)

        {:error, reason} ->
          reply_error("board_items_update_failed", to_string(reason), socket)
      end
    end)
  end

  def handle_in(_event, _payload, socket) do
    reply_error("unknown_event", "Unknown channel event", socket)
  end

  defp with_project(socket, fun) do
    case Avcs.Projects.current_project() do
      nil -> reply_error("no_project", "Open a project folder first", socket)
      project -> fun.(project)
    end
  end

  defp with_project_by_id(project_id, socket, fun) do
    case Avcs.Projects.get_project(project_id) do
      {:ok, %{"status" => "available"} = project} ->
        fun.(project)

      {:ok, _project} ->
        reply_error("project_unavailable", "Project folder is unavailable", socket)

      {:error, reason} ->
        reply_error("project_not_found", to_string(reason), socket)
    end
  end

  defp current_project?(project) do
    case Avcs.Projects.current_project() do
      %{"id" => current_project_id} -> current_project_id == project["id"]
      _project -> false
    end
  end

  defp models_list_reply do
    codex_client = Application.get_env(:avcs, :codex_client, Avcs.Agent.CodexAppServerPool)

    if module_exports?(codex_client, :list_models, 0) do
      case codex_client.list_models() do
        {:ok, models} -> {:ok, ok(%{items: models})}
        {:error, reason} -> {:ok, error("models_list_failed", to_string(reason))}
      end
    else
      {:ok, ok(%{items: []})}
    end
  end

  defp reply_site_settings_error(reason, socket) do
    code = Avcs.SiteSettings.error_code(reason)
    message = Avcs.SiteSettings.error_message(reason)
    details = Avcs.SiteSettings.error_details(reason)
    reply_error(code, message, details, socket)
  end

  defp message_assets_and_settings(project, payload, turn_settings) do
    asset_ids = payload["asset_ids"] || []

    with {:ok, data_provider} <- normalize_data_provider(payload["data_provider"]) do
      turn_settings =
        if data_provider do
          Map.put(turn_settings, :data_provider, data_provider)
        else
          turn_settings
        end

      case normalize_mask_edit(project, payload["mask_edit"], asset_ids) do
        {:ok, nil, asset_ids} ->
          {:ok, asset_ids, turn_settings}

        {:ok, mask_edit, asset_ids} ->
          {:ok, asset_ids, Map.put(turn_settings, :mask_edit, mask_edit)}

        {:error, code, message} ->
          {:error, code, message}
      end
    else
      {:error, reason} ->
        {:error, Avcs.Agent.DataProvider.error_code(reason),
         Avcs.Agent.DataProvider.error_message(reason)}
    end
  end

  defp normalize_data_provider(nil), do: {:ok, nil}

  defp normalize_data_provider(data_provider) do
    Avcs.Agent.DataProvider.normalize(data_provider)
  end

  defp normalize_mask_edit(_project, nil, asset_ids), do: {:ok, nil, asset_ids}

  defp normalize_mask_edit(project, mask_edit, _asset_ids) when is_map(mask_edit) do
    base_asset_id = clean_id(mask_edit["base_asset_id"] || mask_edit[:base_asset_id])
    mask_asset_id = clean_id(mask_edit["mask_asset_id"] || mask_edit[:mask_asset_id])

    with {:ok, base_asset} <- require_message_asset(project, base_asset_id, "Base image"),
         {:ok, mask_asset} <- require_message_asset(project, mask_asset_id, "Mask image"),
         :ok <- ensure_base_asset(base_asset),
         :ok <- ensure_mask_asset(mask_asset) do
      {:ok,
       %{
         "mode" => "visual_reference",
         "base_asset_id" => base_asset_id,
         "mask_asset_id" => mask_asset_id,
         "mask_semantics" => "white_edit_black_keep"
       }, [base_asset_id, mask_asset_id]}
    else
      {:error, message} -> {:error, "invalid_mask_edit", message}
    end
  end

  defp normalize_mask_edit(_project, _mask_edit, _asset_ids) do
    {:error, "invalid_mask_edit", "Mask edit payload is invalid"}
  end

  defp require_message_asset(_project, nil, label), do: {:error, "#{label} is required"}

  defp require_message_asset(project, asset_id, label) do
    case Avcs.Assets.get_asset(project, asset_id) do
      {:ok, nil} ->
        {:error, "#{label} was not found"}

      {:ok, %{"file_path" => path} = asset} ->
        if is_binary(path) and File.exists?(path) do
          {:ok, asset}
        else
          {:error, "#{label} file is missing"}
        end

      {:ok, _asset} ->
        {:error, "#{label} file is missing"}

      {:error, reason} ->
        {:error, to_string(reason)}
    end
  end

  defp ensure_base_asset(%{"source" => "mask"}), do: {:error, "Base image cannot be a mask"}
  defp ensure_base_asset(_asset), do: :ok

  defp ensure_mask_asset(%{"source" => "mask"}), do: :ok
  defp ensure_mask_asset(_asset), do: {:error, "Mask image must be a mask asset"}

  defp clean_id(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      id -> id
    end
  end

  defp clean_id(_value), do: nil

  defp broadcast_threads(project) do
    {:ok, threads} = Avcs.Threads.list_threads(project)

    Avcs.Events.broadcast("threads:updated", %{
      project_id: project["id"],
      items: threads,
      current_thread_id: Avcs.Session.current_thread_id()
    })
  end

  defp next_current_thread_id(current_thread_id, archived_thread_id, threads) do
    thread_ids = Enum.map(threads, & &1["id"])

    if current_thread_id && current_thread_id != archived_thread_id &&
         Enum.member?(thread_ids, current_thread_id) do
      current_thread_id
    else
      List.first(thread_ids)
    end
  end

  defp start_runner(runner, project, thread_id, turn_id, text, asset_ids, turn_settings) do
    if module_exports?(runner, :start, 6) do
      runner.start(project, thread_id, turn_id, text, asset_ids, turn_settings)
    else
      runner.start(project, thread_id, turn_id, text, asset_ids)
    end
  end

  defp submit_runner(runner, project, thread_id, text, asset_ids, turn_settings) do
    if module_exports?(runner, :submit, 5) do
      runner.submit(project, thread_id, text, asset_ids, turn_settings)
    else
      with {:ok, created} <-
             Avcs.Turns.create_user_turn(project, thread_id, text, asset_ids, turn_settings),
           {:ok, _pid} <-
             start_runner(
               runner,
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
  end

  defp stop_runner(runner, project, thread_id, turn_id) do
    if module_exports?(runner, :stop, 3) do
      runner.stop(project, thread_id, turn_id)
    else
      {:error, :interrupt_unsupported}
    end
  end

  defp rerun_runner(runner, project, item_id, content) do
    if module_exports?(runner, :rerun_from_item, 3) do
      runner.rerun_from_item(project, item_id, content)
    else
      {:error, :message_edit_unsupported}
    end
  end

  defp require_thread_id(thread_id) when is_binary(thread_id) do
    case String.trim(thread_id) do
      "" -> {:error, :thread_required}
      id -> {:ok, id}
    end
  end

  defp require_thread_id(_thread_id), do: {:error, :thread_required}

  defp require_thread(project, thread_id) do
    case Avcs.Threads.get_thread(project, thread_id) do
      {:ok, nil} -> {:error, :thread_not_found}
      {:ok, thread} -> {:ok, thread}
      {:error, _reason} -> {:error, :thread_not_found}
    end
  end

  defp repair_thread(project, thread_id) do
    runner = Application.get_env(:avcs, :agent_runner, Avcs.Agent.Runner)

    if module_exports?(runner, :repair_thread, 2) do
      runner.repair_thread(project, thread_id)
    else
      Avcs.Agent.Runner.repair_thread(project, thread_id)
    end
  end

  defp apply_approval_response(project, item, "deny") do
    with {:ok, updated_item} <-
           Avcs.Turns.update_item(project, item["id"],
             status: "denied",
             payload: Avcs.Agent.ApprovalReview.response_payload(item, "deny")
           ) do
      Avcs.Turns.update_turn_status(project, item["turn_id"], "in_progress", nil)
      trace_approval_response(project, updated_item, "deny")
      {:ok, updated_item}
    end
  end

  defp apply_approval_response(project, item, "approve") do
    with {:ok, event} <- approval_event(item),
         :ok <- send_runner_approval(item, event) do
      with {:ok, updated_item} <-
             Avcs.Turns.update_item(project, item["id"],
               status: "approved",
               payload: Avcs.Agent.ApprovalReview.response_payload(item, "approve")
             ) do
        Avcs.Turns.update_turn_status(project, item["turn_id"], "in_progress", nil)
        trace_approval_response(project, updated_item, "approve")
        {:ok, updated_item}
      end
    end
  end

  defp trace_approval_response(project, item, decision) do
    raw = Avcs.Agent.ApprovalReview.event_from_item(item)

    Avcs.Trace.append_event(project, %{
      scope: "approval",
      event_name: "approval_response_recorded",
      thread_id: item["thread_id"],
      turn_id: item["turn_id"],
      item_id: item["id"],
      codex_item_id: item["codex_item_id"],
      status: item["status"],
      payload: %{
        decision: decision,
        review_id: item["payload"]["review_id"],
        target_item_id: item["payload"]["target_item_id"]
      },
      raw: if(is_map(raw), do: raw)
    })

    :ok
  end

  defp approval_event(item) do
    case Avcs.Agent.ApprovalReview.event_from_item(item) do
      event when is_map(event) -> {:ok, event}
      _event -> {:error, :missing_event}
    end
  end

  defp send_runner_approval(item, event) do
    runner = Application.get_env(:avcs, :agent_runner, Avcs.Agent.Runner)

    payload = %{
      decision: "approve",
      review_id: item["payload"]["review_id"],
      event: event
    }

    if module_exports?(runner, :respond_approval, 3) do
      runner.respond_approval(item["thread_id"], item["turn_id"], payload)
    else
      {:error, :not_running}
    end
  end

  defp module_exports?(module, function, arity) when is_atom(module) do
    Code.ensure_loaded?(module) and function_exported?(module, function, arity)
  end

  defp module_exports?(_module, _function, _arity), do: false

  defp clean_decision(decision) when decision in ["approve", "deny"], do: decision
  defp clean_decision(_decision), do: nil

  defp require_decision(nil), do: {:error, :invalid_decision}
  defp require_decision(decision), do: {:ok, decision}

  defp ok(data), do: %{success: true, data: data}

  defp error(code, message, details \\ nil) do
    error = %{code: code, message: message}
    error = if details, do: Map.put(error, :details, details), else: error
    %{success: false, data: nil, error: error}
  end

  defp reply_ok(data, socket), do: {:reply, {:ok, ok(data)}, socket}

  defp reply_error(code, message, socket),
    do: {:reply, {:ok, error(code, message)}, socket}

  defp reply_error(code, message, details, socket),
    do: {:reply, {:ok, error(code, message, details)}, socket}
end
