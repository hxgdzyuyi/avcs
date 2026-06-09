defmodule Avcs.Turns do
  @moduledoc false

  alias Avcs.Storage.SQLite

  @default_page_limit 30
  @max_page_limit 100
  @running_statuses ~w(queued in_progress waiting_approval)

  def list_items(project, thread_id) do
    with_project_db(project, fn db ->
      SQLite.all!(
        db,
        """
        SELECT items.*, turns.status AS turn_status, turns.user_text AS turn_user_text
             , turns.model AS turn_model, turns.effort AS turn_effort
             , turns.approval_policy AS turn_approval_policy
             , turns.sandbox_mode AS turn_sandbox_mode
             , turns.data_provider AS turn_data_provider
             , turns.agent_harness AS turn_agent_harness
             , turns.remote_model AS turn_remote_model
             , turns.created_at AS turn_created_at, turns.updated_at AS turn_updated_at
             , turns.completed_at AS turn_completed_at, turns.error AS turn_error
        FROM items
        LEFT JOIN turns ON turns.id = items.turn_id
        WHERE items.thread_id = ?
          AND items.invalidated_at IS NULL
          AND COALESCE(turns.invalidated_at, '') = ''
        ORDER BY items.created_at ASC
        """,
        [thread_id]
      )
      |> Enum.map(&decode_item/1)
    end)
  end

  def list_item_page(project, thread_id, opts \\ %{}) do
    with {:ok, page_opts} <- normalize_page_opts(opts) do
      case with_project_db(project, fn db ->
             do_list_item_page(db, thread_id, page_opts)
           end) do
        {:ok, {:error, _reason} = error} -> error
        {:ok, result} -> {:ok, result}
        error -> error
      end
    end
  end

  def create_user_turn(project, thread_id, text, reference_assets, opts \\ []) do
    with_project_db(project, fn db ->
      SQLite.transaction!(db, fn ->
        now = Avcs.Time.now_iso()
        turn_id = Ecto.UUID.generate()
        item_id = Ecto.UUID.generate()

        model = attr(opts, :model)
        agent_harness = attr(opts, :agent_harness)
        remote_model = attr(opts, :remote_model)
        effort = attr(opts, :effort)
        approval_policy = attr(opts, :approval_policy) || "never"
        sandbox_mode = attr(opts, :sandbox_mode) || "workspace-write"
        data_provider = attr(opts, :data_provider)
        data_provider_payload = encode_optional_json(data_provider)
        status = attr(opts, :status) || "in_progress"

        payload =
          reference_payload(reference_assets, attr(opts, :mask_edit), data_provider)
          |> Jason.encode!()

        SQLite.run!(
          db,
          """
          INSERT INTO turns (
            id, thread_id, agent_harness, remote_model, status, user_text, model,
            effort, approval_policy, sandbox_mode, data_provider, created_at, updated_at
          )
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          """,
          [
            turn_id,
            thread_id,
            agent_harness,
            remote_model,
            status,
            text,
            model,
            effort,
            approval_policy,
            sandbox_mode,
            data_provider_payload,
            now,
            now
          ]
        )

        SQLite.run!(
          db,
          """
          INSERT INTO items (
            id, turn_id, thread_id, type, role, content, payload, status, created_at, updated_at
          )
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          """,
          [
            item_id,
            turn_id,
            thread_id,
            "user_message",
            "user",
            text,
            payload,
            "completed",
            now,
            now
          ]
        )

        SQLite.run!(
          db,
          "UPDATE threads SET updated_at = ? WHERE id = ?",
          [now, thread_id]
        )

        Avcs.Trace.append_event(
          project,
          %{
            scope: "turn",
            event_name: "turn_created",
            thread_id: thread_id,
            turn_id: turn_id,
            status: status,
            payload: %{
              user_text: text,
              asset_ids: reference_assets,
              model: model,
              effort: effort,
              approval_policy: approval_policy,
              sandbox_mode: sandbox_mode,
              agent_harness: agent_harness,
              remote_model: remote_model,
              data_provider: data_provider
            }
          },
          db: db
        )

        Avcs.Trace.append_event(
          project,
          %{
            scope: "item",
            event_name: "item_created",
            thread_id: thread_id,
            turn_id: turn_id,
            item_id: item_id,
            status: "completed",
            payload: %{
              type: "user_message",
              role: "user",
              content: content_snapshot(text),
              asset_ids: reference_assets
            }
          },
          db: db
        )

        %{
          "turn" => decode_turn(SQLite.one!(db, "SELECT * FROM turns WHERE id = ?", [turn_id])),
          "item" => decode_item(SQLite.one!(db, "SELECT * FROM items WHERE id = ?", [item_id]))
        }
      end)
    end)
  end

  def edit_and_invalidate_after(project, item_id, content, opts \\ []) do
    status = attr(opts, :status) || "in_progress"

    case with_project_db(project, fn db ->
           SQLite.transaction!(db, fn ->
             do_edit_and_invalidate_after(project, db, item_id, content, status)
           end)
         end) do
      {:ok, {:error, _reason} = error} -> error
      {:ok, result} -> {:ok, result}
      error -> error
    end
  end

  def list_turns(project, thread_id) do
    with_project_db(project, fn db ->
      SQLite.all!(
        db,
        """
        SELECT *
        FROM turns
        WHERE thread_id = ?
          AND invalidated_at IS NULL
        ORDER BY created_at ASC
        """,
        [thread_id]
      )
      |> Enum.map(&decode_turn/1)
    end)
  end

  def get_turn(project, turn_id) do
    with_project_db(project, fn db ->
      SQLite.one!(db, "SELECT * FROM turns WHERE id = ? LIMIT 1", [turn_id])
      |> decode_turn()
    end)
  end

  def append_item(project, attrs) do
    with_project_db(project, fn db ->
      now = Avcs.Time.now_iso()
      id = attr(attrs, :id) || Ecto.UUID.generate()
      type = attr(attrs, :type)
      thread_id = attr(attrs, :thread_id)
      turn_id = attr(attrs, :turn_id)
      remote_item_id = attr(attrs, :remote_item_id)
      tool_name = attr(attrs, :tool_name)
      role = attr(attrs, :role)
      content = attr(attrs, :content)
      status = attr(attrs, :status) || "completed"
      payload = attr(attrs, :payload) || %{}

      SQLite.run!(
        db,
        """
        INSERT INTO items (
          id, turn_id, thread_id, remote_item_id, tool_name, type, role, content, payload,
          status, created_at, updated_at
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        [
          id,
          turn_id,
          thread_id,
          remote_item_id,
          tool_name,
          type,
          role,
          content,
          Jason.encode!(payload),
          status,
          now,
          now
        ]
      )

      item = decode_item(SQLite.one!(db, "SELECT * FROM items WHERE id = ?", [id]))

      Avcs.Trace.append_event(
        project,
        %{
          scope: "item",
          event_name: "item_created",
          thread_id: thread_id,
          turn_id: turn_id,
          item_id: id,
          remote_item_id: remote_item_id,
          tool_name: tool_name,
          status: status,
          payload: %{current: item_trace_snapshot(item)}
        },
        db: db
      )

      item
    end)
  end

  def upsert_remote_item(project, attrs) do
    with_project_db(project, fn db ->
      SQLite.transaction!(db, fn ->
        now = Avcs.Time.now_iso()
        thread_id = attr(attrs, :thread_id)
        turn_id = attr(attrs, :turn_id)
        remote_item_id = attr(attrs, :remote_item_id)
        tool_name = attr(attrs, :tool_name)
        type = attr(attrs, :type)
        role = attr(attrs, :role)
        content = attr(attrs, :content)
        status = attr(attrs, :status) || "completed"
        payload = attr(attrs, :payload) || %{}

        existing =
          if remote_item_id do
            SQLite.one!(
              db,
              """
              SELECT * FROM items
              WHERE thread_id = ? AND turn_id = ? AND remote_item_id = ?
              LIMIT 1
              """,
              [thread_id, turn_id, remote_item_id]
            )
          end

        if existing do
          previous = decode_item(existing)

          SQLite.run!(
            db,
            """
            UPDATE items
            SET type = ?, role = ?, content = ?, payload = ?, status = ?,
                tool_name = COALESCE(?, tool_name), updated_at = ?
            WHERE id = ?
            """,
            [type, role, content, Jason.encode!(payload), status, tool_name, now, existing["id"]]
          )

          item =
            decode_item(SQLite.one!(db, "SELECT * FROM items WHERE id = ?", [existing["id"]]))

          Avcs.Trace.append_event(
            project,
            %{
              scope: "item",
              event_name: "item_updated",
              thread_id: thread_id,
              turn_id: turn_id,
              item_id: existing["id"],
              remote_item_id: remote_item_id,
              tool_name: tool_name,
              status: status,
              payload: %{
                previous: item_trace_snapshot(previous),
                current: item_trace_snapshot(item)
              }
            },
            db: db
          )

          item
        else
          id = attr(attrs, :id) || Ecto.UUID.generate()

          SQLite.run!(
            db,
            """
            INSERT INTO items (
              id, turn_id, thread_id, remote_item_id, tool_name, type, role, content, payload,
              status, created_at, updated_at
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [
              id,
              turn_id,
              thread_id,
              remote_item_id,
              tool_name,
              type,
              role,
              content,
              Jason.encode!(payload),
              status,
              now,
              now
            ]
          )

          item = decode_item(SQLite.one!(db, "SELECT * FROM items WHERE id = ?", [id]))

          Avcs.Trace.append_event(
            project,
            %{
              scope: "item",
              event_name: "item_created",
              thread_id: thread_id,
              turn_id: turn_id,
              item_id: id,
              remote_item_id: remote_item_id,
              tool_name: tool_name,
              status: status,
              payload: %{current: item_trace_snapshot(item)}
            },
            db: db
          )

          item
        end
      end)
    end)
  end

  def get_approval_item(project, thread_id, turn_id, review_id) do
    case with_project_db(project, fn db ->
           db
           |> SQLite.one!(
             """
             SELECT * FROM items
             WHERE thread_id = ?
               AND turn_id = ?
               AND remote_item_id = ?
               AND type = 'approval_request'
             LIMIT 1
             """,
             [thread_id, turn_id, review_id]
           )
           |> decode_item()
         end) do
      {:ok, nil} -> {:error, :not_found}
      {:ok, item} -> {:ok, item}
      error -> error
    end
  end

  def update_item(project, id, attrs) do
    case with_project_db(project, fn db ->
           SQLite.transaction!(db, fn ->
             existing =
               decode_item(SQLite.one!(db, "SELECT * FROM items WHERE id = ? LIMIT 1", [id]))

             if is_nil(existing) do
               nil
             else
               now = Avcs.Time.now_iso()
               content = attr(attrs, :content)
               payload = Map.merge(existing["payload"] || %{}, attr(attrs, :payload) || %{})

               SQLite.run!(
                 db,
                 """
                 UPDATE items
                 SET content = COALESCE(?, content),
                     payload = ?,
                     status = COALESCE(?, status),
                     updated_at = ?
                 WHERE id = ?
                 """,
                 [
                   content,
                   Jason.encode!(payload),
                   attr(attrs, :status),
                   now,
                   id
                 ]
               )

               if existing["type"] == "user_message" and not is_nil(content) do
                 SQLite.run!(
                   db,
                   "UPDATE turns SET user_text = ?, updated_at = ? WHERE id = ?",
                   [content, now, existing["turn_id"]]
                 )
               end

               item = decode_item(SQLite.one!(db, "SELECT * FROM items WHERE id = ?", [id]))

               Avcs.Trace.append_event(
                 project,
                 %{
                   scope: "item",
                   event_name: "item_updated",
                   thread_id: item["thread_id"],
                   turn_id: item["turn_id"],
                   item_id: id,
                   remote_item_id: item["remote_item_id"],
                   status: item["status"],
                   payload: %{
                     previous: item_trace_snapshot(existing),
                     current: item_trace_snapshot(item)
                   }
                 },
                 db: db
               )

               item
             end
           end)
         end) do
      {:ok, nil} -> {:error, :not_found}
      {:ok, item} -> {:ok, item}
      error -> error
    end
  end

  def complete_turn(project, turn_id, remote_turn_id \\ nil, opts \\ []) do
    update_turn_status(project, turn_id, "completed", remote_turn_id, nil, opts)
  end

  def interrupt_turn(project, turn_id, remote_turn_id \\ nil, reason \\ "Stopped by user") do
    update_turn_status(project, turn_id, "interrupted", remote_turn_id, reason)
  end

  def fail_turn(project, turn_id, reason) do
    with {:ok, turn} <- update_turn_status(project, turn_id, "failed", nil, to_string(reason)) do
      append_item(project,
        turn_id: turn_id,
        thread_id: turn["thread_id"],
        type: "error",
        role: "system",
        content: to_string(reason),
        payload: %{message: to_string(reason)}
      )
    end
  end

  def update_turn_status(project, turn_id, status, remote_turn_id, error \\ nil, opts \\ []) do
    case with_project_db(project, fn db ->
           SQLite.transaction!(db, fn ->
             existing = SQLite.one!(db, "SELECT * FROM turns WHERE id = ? LIMIT 1", [turn_id])

             if is_nil(existing) do
               {:error, :turn_not_found}
             else
               now = Avcs.Time.now_iso()
               completed_at = if status in ["completed", "failed", "interrupted"], do: now
               agent_harness = attr(opts, :agent_harness)
               remote_model = attr(opts, :remote_model)

               SQLite.run!(
                 db,
                 """
                 UPDATE turns
                 SET status = ?,
                     agent_harness = COALESCE(?, agent_harness),
                     remote_turn_id = COALESCE(?, remote_turn_id),
                     remote_model = COALESCE(?, remote_model),
                     completed_at = COALESCE(?, completed_at),
                     error = COALESCE(?, error),
                     updated_at = ?
                 WHERE id = ?
                 """,
                 [
                   status,
                   agent_harness,
                   remote_turn_id,
                   remote_model,
                   completed_at,
                   error,
                   now,
                   turn_id
                 ]
               )

               turn = decode_turn(SQLite.one!(db, "SELECT * FROM turns WHERE id = ?", [turn_id]))

               if trace_turn_update?(existing, turn, status, remote_turn_id, error) do
                 Avcs.Trace.append_event(
                   project,
                   %{
                     scope: "turn",
                     event_name: turn_event_name(existing, turn),
                     thread_id: turn["thread_id"],
                     turn_id: turn_id,
                     agent_harness: turn["agent_harness"],
                     model: turn["remote_model"],
                     remote_turn_id: turn["remote_turn_id"],
                     status: turn["status"],
                     payload: %{
                       from_status: existing && existing["status"],
                       to_status: turn["status"],
                       previous_remote_turn_id: existing && existing["remote_turn_id"],
                       remote_turn_id: turn["remote_turn_id"],
                       error: error
                     }
                   },
                   db: db
                 )
               end

               turn
             end
           end)
         end) do
      {:ok, {:error, _reason} = error} -> error
      result -> result
    end
  end

  defp do_edit_and_invalidate_after(project, db, item_id, content, status) do
    with {:ok, content} <- normalize_edit_content(content),
         {:ok, item} <- editable_user_item(db, item_id),
         {:ok, turn} <- editable_turn(db, item["turn_id"]),
         :ok <- ensure_thread_not_running(db, turn["thread_id"]),
         :ok <- ensure_starting_user_item(db, item),
         now = Avcs.Time.now_iso(),
         {:ok, invalidated} <- invalidate_after_item(db, turn, item, now),
         {:ok, updated} <- update_edited_anchor(db, turn, item, content, status, now) do
      trace_edit_rerun(project, db, updated, invalidated, content)

      Map.merge(updated, %{
        "asset_ids" => payload_asset_ids(updated["item"]["payload"]),
        "invalidated_item_ids" => invalidated.item_ids,
        "invalidated_turn_ids" => invalidated.turn_ids,
        "rollback_turn_count" => length(invalidated.turn_ids) + 1,
        "turn_settings" => turn_settings(updated["turn"], updated["item"]["payload"])
      })
    end
  end

  defp normalize_edit_content(content) when is_binary(content) do
    case String.trim(content) do
      "" -> {:error, :empty_message}
      trimmed -> {:ok, trimmed}
    end
  end

  defp normalize_edit_content(_content), do: {:error, :empty_message}

  defp editable_user_item(db, item_id) when is_binary(item_id) and item_id != "" do
    db
    |> SQLite.one!(
      """
      SELECT *
      FROM items
      WHERE id = ?
        AND invalidated_at IS NULL
      LIMIT 1
      """,
      [item_id]
    )
    |> decode_item()
    |> case do
      nil ->
        {:error, :item_not_found}

      %{"type" => "user_message", "payload" => %{"steered" => true}} ->
        {:error, :message_edit_unsupported}

      %{"type" => "user_message"} = item ->
        {:ok, item}

      _item ->
        {:error, :message_edit_unsupported}
    end
  end

  defp editable_user_item(_db, _item_id), do: {:error, :item_not_found}

  defp editable_turn(db, turn_id) when is_binary(turn_id) and turn_id != "" do
    db
    |> SQLite.one!(
      """
      SELECT *
      FROM turns
      WHERE id = ?
        AND invalidated_at IS NULL
      LIMIT 1
      """,
      [turn_id]
    )
    |> decode_turn()
    |> case do
      nil -> {:error, :item_not_found}
      %{"status" => status} when status in @running_statuses -> {:error, :message_edit_conflict}
      turn -> {:ok, turn}
    end
  end

  defp editable_turn(_db, _turn_id), do: {:error, :item_not_found}

  defp ensure_thread_not_running(db, thread_id) do
    count =
      SQLite.scalar!(
        db,
        """
        SELECT COUNT(*)
        FROM turns
        WHERE thread_id = ?
          AND invalidated_at IS NULL
          AND status IN (#{placeholders(@running_statuses)})
        """,
        [thread_id | @running_statuses]
      )

    if count == 0, do: :ok, else: {:error, :message_edit_conflict}
  end

  defp ensure_starting_user_item(db, item) do
    earlier_count =
      SQLite.scalar!(
        db,
        """
        SELECT COUNT(*)
        FROM items
        WHERE thread_id = ?
          AND turn_id = ?
          AND type = 'user_message'
          AND invalidated_at IS NULL
          AND (created_at < ? OR (created_at = ? AND id < ?))
        """,
        [
          item["thread_id"],
          item["turn_id"],
          item["created_at"],
          item["created_at"],
          item["id"]
        ]
      )

    if earlier_count == 0, do: :ok, else: {:error, :message_edit_unsupported}
  end

  defp invalidate_after_item(db, turn, item, now) do
    turn_ids = later_turn_ids(db, turn)
    item_ids = Enum.uniq(later_item_ids(db, turn_ids) ++ later_item_ids_in_anchor_turn(db, item))

    mark_turns_invalidated(db, turn_ids, item["id"], now)
    mark_items_invalidated(db, item_ids, item["id"], now)
    mark_linked_rows_invalidated(db, "asset_links", turn_ids, item_ids, item["id"], now)
    mark_linked_rows_invalidated(db, "board_items", turn_ids, item_ids, item["id"], now)

    {:ok, %{item_ids: item_ids, turn_ids: turn_ids}}
  end

  defp later_turn_ids(db, turn) do
    SQLite.all!(
      db,
      """
      SELECT id
      FROM turns
      WHERE thread_id = ?
        AND invalidated_at IS NULL
        AND (created_at > ? OR (created_at = ? AND id > ?))
      ORDER BY created_at ASC, id ASC
      """,
      [turn["thread_id"], turn["created_at"], turn["created_at"], turn["id"]]
    )
    |> Enum.map(& &1["id"])
  end

  defp later_item_ids(_db, []), do: []

  defp later_item_ids(db, turn_ids) do
    SQLite.all!(
      db,
      """
      SELECT id
      FROM items
      WHERE turn_id IN (#{placeholders(turn_ids)})
        AND invalidated_at IS NULL
      ORDER BY created_at ASC, id ASC
      """,
      turn_ids
    )
    |> Enum.map(& &1["id"])
  end

  defp later_item_ids_in_anchor_turn(db, item) do
    SQLite.all!(
      db,
      """
      SELECT id
      FROM items
      WHERE thread_id = ?
        AND turn_id = ?
        AND invalidated_at IS NULL
        AND id != ?
      ORDER BY created_at ASC, id ASC
      """,
      [item["thread_id"], item["turn_id"], item["id"]]
    )
    |> Enum.map(& &1["id"])
  end

  defp update_edited_anchor(db, turn, item, content, status, now) do
    payload =
      item["payload"]
      |> Map.put("edited_at", now)
      |> Map.put("previous_content", item["content"])

    SQLite.run!(
      db,
      """
      UPDATE items
      SET content = ?,
          payload = ?,
          status = 'completed',
          updated_at = ?
      WHERE id = ?
      """,
      [content, Jason.encode!(payload), now, item["id"]]
    )

    SQLite.run!(
      db,
      """
      UPDATE turns
      SET status = ?,
          user_text = ?,
          remote_turn_id = NULL,
          remote_model = NULL,
          completed_at = NULL,
          error = NULL,
          updated_at = ?
      WHERE id = ?
      """,
      [status, content, now, turn["id"]]
    )

    SQLite.run!(
      db,
      "UPDATE threads SET updated_at = ? WHERE id = ?",
      [now, turn["thread_id"]]
    )

    {:ok,
     %{
       "item" => decode_item(SQLite.one!(db, "SELECT * FROM items WHERE id = ?", [item["id"]])),
       "turn" => decode_turn(SQLite.one!(db, "SELECT * FROM turns WHERE id = ?", [turn["id"]]))
     }}
  end

  defp mark_turns_invalidated(_db, [], _item_id, _now), do: :ok

  defp mark_turns_invalidated(db, turn_ids, item_id, now) do
    SQLite.run!(
      db,
      """
      UPDATE turns
      SET invalidated_at = ?,
          invalidated_by_item_id = ?,
          updated_at = ?
      WHERE id IN (#{placeholders(turn_ids)})
        AND invalidated_at IS NULL
      """,
      [now, item_id, now | turn_ids]
    )
  end

  defp mark_items_invalidated(_db, [], _item_id, _now), do: :ok

  defp mark_items_invalidated(db, item_ids, item_id, now) do
    SQLite.run!(
      db,
      """
      UPDATE items
      SET invalidated_at = ?,
          invalidated_by_item_id = ?,
          updated_at = ?
      WHERE id IN (#{placeholders(item_ids)})
        AND invalidated_at IS NULL
      """,
      [now, item_id, now | item_ids]
    )
  end

  defp mark_linked_rows_invalidated(_db, _table, [], [], _item_id, _now), do: :ok

  defp mark_linked_rows_invalidated(db, table, turn_ids, item_ids, item_id, now) do
    {conditions, params} = invalidation_conditions(turn_ids, item_ids)

    SQLite.run!(
      db,
      """
      UPDATE #{table}
      SET invalidated_at = ?,
          invalidated_by_item_id = ?
      WHERE invalidated_at IS NULL
        AND (#{Enum.join(conditions, " OR ")})
      """,
      [now, item_id | params]
    )
  end

  defp invalidation_conditions(turn_ids, item_ids) do
    pairs =
      []
      |> maybe_add_in_condition("turn_id", turn_ids)
      |> maybe_add_in_condition("item_id", item_ids)
      |> Enum.reverse()

    {Enum.map(pairs, &elem(&1, 0)), Enum.flat_map(pairs, &elem(&1, 1))}
  end

  defp maybe_add_in_condition(conditions, _field, []), do: conditions

  defp maybe_add_in_condition(conditions, field, values) do
    [{"#{field} IN (#{placeholders(values)})", values} | conditions]
  end

  defp trace_edit_rerun(project, db, updated, invalidated, content) do
    Avcs.Trace.append_event(
      project,
      %{
        scope: "turn",
        event_name: "message_edit_rerun",
        thread_id: updated["turn"]["thread_id"],
        turn_id: updated["turn"]["id"],
        item_id: updated["item"]["id"],
        status: updated["turn"]["status"],
        payload: %{
          content: content_snapshot(content),
          invalidated_item_ids: invalidated.item_ids,
          invalidated_turn_ids: invalidated.turn_ids
        }
      },
      db: db
    )
  end

  defp payload_asset_ids(payload) when is_map(payload) do
    case payload["asset_ids"] || payload[:asset_ids] do
      ids when is_list(ids) -> Enum.filter(ids, &is_binary/1)
      _ids -> []
    end
  end

  defp payload_asset_ids(_payload), do: []

  defp turn_settings(turn, payload) do
    %{
      approval_policy: turn["approval_policy"] || "never",
      data_provider: turn["data_provider"],
      effort: turn["effort"],
      agent_harness: turn["agent_harness"],
      mask_edit: payload["mask_edit"] || payload[:mask_edit],
      model: turn["model"],
      remote_model: turn["remote_model"],
      sandbox_mode: turn["sandbox_mode"] || "workspace-write"
    }
  end

  defp do_list_item_page(_db, thread_id, page_opts)
       when not is_binary(thread_id) or thread_id == "" do
    empty_item_page(thread_id, page_opts)
  end

  defp do_list_item_page(db, thread_id, %{mode: :latest} = page_opts) do
    limit = page_opts.limit

    turns =
      SQLite.all!(
        db,
        """
        SELECT *
        FROM turns
        WHERE thread_id = ?
          AND invalidated_at IS NULL
        ORDER BY created_at DESC, id DESC
        LIMIT ?
        """,
        [thread_id, limit + 1]
      )

    {page_turns, has_more_before} = take_page_with_more(turns, limit)
    page_turns = Enum.reverse(page_turns)

    item_page_result(thread_id, page_turns, db,
      mode: "latest",
      limit: limit,
      has_more_before: has_more_before,
      has_more_after: false,
      at_latest: true
    )
  end

  defp do_list_item_page(db, thread_id, %{mode: :before, before: cursor} = page_opts) do
    limit = page_opts.limit

    with {:ok, _cursor_turn} <- validate_cursor(db, thread_id, cursor) do
      turns =
        SQLite.all!(
          db,
          """
          SELECT *
          FROM turns
          WHERE thread_id = ?
            AND invalidated_at IS NULL
            AND (created_at < ? OR (created_at = ? AND id < ?))
          ORDER BY created_at DESC, id DESC
          LIMIT ?
          """,
          [thread_id, cursor.created_at, cursor.created_at, cursor.id, limit + 1]
        )

      {page_turns, has_more_before} = take_page_with_more(turns, limit)
      page_turns = Enum.reverse(page_turns)

      item_page_result(thread_id, page_turns, db,
        mode: "before",
        limit: limit,
        has_more_before: has_more_before,
        has_more_after: true,
        at_latest: false
      )
    end
  end

  defp do_list_item_page(db, thread_id, %{mode: :after} = page_opts) do
    cursor = Map.fetch!(page_opts, :after)
    limit = page_opts.limit

    with {:ok, _cursor_turn} <- validate_cursor(db, thread_id, cursor) do
      turns =
        SQLite.all!(
          db,
          """
          SELECT *
          FROM turns
          WHERE thread_id = ?
            AND invalidated_at IS NULL
            AND (created_at > ? OR (created_at = ? AND id > ?))
          ORDER BY created_at ASC, id ASC
          LIMIT ?
          """,
          [thread_id, cursor.created_at, cursor.created_at, cursor.id, limit + 1]
        )

      {page_turns, has_more_after} = take_page_with_more(turns, limit)

      item_page_result(thread_id, page_turns, db,
        mode: "after",
        limit: limit,
        has_more_before: true,
        has_more_after: has_more_after,
        at_latest: not has_more_after
      )
    end
  end

  defp do_list_item_page(db, thread_id, %{mode: :around, around: %{turn_id: turn_id}} = page_opts) do
    limit = page_opts.limit

    anchor =
      SQLite.one!(
        db,
        """
        SELECT *
        FROM turns
        WHERE thread_id = ? AND id = ?
          AND invalidated_at IS NULL
        LIMIT 1
        """,
        [thread_id, turn_id]
      )

    if anchor do
      older_limit = div(limit - 1, 2)
      newer_limit = limit - 1 - older_limit

      older_turns =
        SQLite.all!(
          db,
          """
          SELECT *
          FROM turns
          WHERE thread_id = ?
            AND invalidated_at IS NULL
            AND (created_at < ? OR (created_at = ? AND id < ?))
          ORDER BY created_at DESC, id DESC
          LIMIT ?
          """,
          [thread_id, anchor["created_at"], anchor["created_at"], anchor["id"], older_limit + 1]
        )

      newer_turns =
        SQLite.all!(
          db,
          """
          SELECT *
          FROM turns
          WHERE thread_id = ?
            AND invalidated_at IS NULL
            AND (created_at > ? OR (created_at = ? AND id > ?))
          ORDER BY created_at ASC, id ASC
          LIMIT ?
          """,
          [thread_id, anchor["created_at"], anchor["created_at"], anchor["id"], newer_limit + 1]
        )

      {older_turns, has_more_before} = take_page_with_more(older_turns, older_limit)
      {newer_turns, has_more_after} = take_page_with_more(newer_turns, newer_limit)
      page_turns = Enum.reverse(older_turns) ++ [anchor] ++ newer_turns
      latest_turn_id = latest_turn_id(db, thread_id)

      item_page_result(thread_id, page_turns, db,
        mode: "around",
        limit: limit,
        anchor_turn_id: turn_id,
        has_more_before: has_more_before,
        has_more_after: has_more_after,
        at_latest: latest_turn_id == turn_id
      )
    else
      {:error, :turn_anchor_not_found}
    end
  end

  defp normalize_page_opts(opts) do
    page_params =
      [:before, :after, :around]
      |> Enum.map(fn key -> {key, page_param(opts, key)} end)
      |> Enum.filter(fn {_key, value} -> value != :absent end)

    if length(page_params) > 1 do
      {:error, :invalid_page_cursor}
    else
      limit = normalize_limit(attr(opts, :limit))

      case page_params do
        [] ->
          {:ok, %{mode: :latest, limit: limit}}

        [{:before, value}] ->
          with {:ok, cursor} <- normalize_cursor(value) do
            {:ok, %{mode: :before, limit: limit, before: cursor}}
          end

        [{:after, value}] ->
          with {:ok, cursor} <- normalize_cursor(value) do
            {:ok, %{:after => cursor, mode: :after, limit: limit}}
          end

        [{:around, value}] ->
          with {:ok, around} <- normalize_around(value) do
            {:ok, %{mode: :around, limit: limit, around: around}}
          end
      end
    end
  end

  defp page_param(opts, key) when is_list(opts) do
    if Keyword.has_key?(opts, key) do
      Keyword.get(opts, key)
    else
      :absent
    end
  end

  defp page_param(opts, key) when is_map(opts) do
    string_key = Atom.to_string(key)

    cond do
      Map.has_key?(opts, key) -> Map.get(opts, key)
      Map.has_key?(opts, string_key) -> Map.get(opts, string_key)
      true -> :absent
    end
  end

  defp page_param(_opts, _key), do: :absent

  defp normalize_cursor(%{} = cursor) do
    created_at = Map.get(cursor, :created_at) || Map.get(cursor, "created_at")
    id = Map.get(cursor, :id) || Map.get(cursor, "id")

    if is_binary(created_at) and created_at != "" and is_binary(id) and id != "" do
      {:ok, %{created_at: created_at, id: id}}
    else
      {:error, :invalid_page_cursor}
    end
  end

  defp normalize_cursor(_cursor), do: {:error, :invalid_page_cursor}

  defp normalize_around(%{} = around) do
    turn_id = Map.get(around, :turn_id) || Map.get(around, "turn_id")

    if is_binary(turn_id) and turn_id != "" do
      {:ok, %{turn_id: turn_id}}
    else
      {:error, :invalid_page_cursor}
    end
  end

  defp normalize_around(_around), do: {:error, :invalid_page_cursor}

  defp normalize_limit(nil), do: @default_page_limit

  defp normalize_limit(limit) when is_integer(limit) do
    limit
    |> max(1)
    |> min(@max_page_limit)
  end

  defp normalize_limit(limit) when is_binary(limit) do
    case Integer.parse(limit) do
      {parsed, ""} -> normalize_limit(parsed)
      _other -> @default_page_limit
    end
  end

  defp normalize_limit(_limit), do: @default_page_limit

  defp validate_cursor(db, thread_id, cursor) do
    turn =
      SQLite.one!(
        db,
        """
        SELECT *
        FROM turns
        WHERE thread_id = ? AND id = ? AND created_at = ?
          AND invalidated_at IS NULL
        LIMIT 1
        """,
        [thread_id, cursor.id, cursor.created_at]
      )

    if turn do
      {:ok, turn}
    else
      {:error, :invalid_page_cursor}
    end
  end

  defp item_page_result(thread_id, turns, db, page_attrs) do
    items = list_items_for_turns(db, thread_id, turns)
    before_cursor = turns |> List.first() |> turn_cursor()
    after_cursor = turns |> List.last() |> turn_cursor()

    %{
      thread_id: thread_id,
      items: items,
      page: %{
        mode: Keyword.fetch!(page_attrs, :mode),
        limit: Keyword.fetch!(page_attrs, :limit),
        turn_count: length(turns),
        anchor_turn_id: Keyword.get(page_attrs, :anchor_turn_id),
        before_cursor: before_cursor,
        after_cursor: after_cursor,
        has_more_before: Keyword.get(page_attrs, :has_more_before, false),
        has_more_after: Keyword.get(page_attrs, :has_more_after, false),
        at_latest: Keyword.get(page_attrs, :at_latest, false)
      }
    }
  end

  defp empty_item_page(thread_id, page_opts) do
    %{
      thread_id: thread_id,
      items: [],
      page: %{
        mode: page_opts.mode |> Atom.to_string(),
        limit: page_opts.limit,
        turn_count: 0,
        anchor_turn_id: nil,
        before_cursor: nil,
        after_cursor: nil,
        has_more_before: false,
        has_more_after: false,
        at_latest: true
      }
    }
  end

  defp take_page_with_more(rows, limit) do
    page_rows = Enum.take(rows, limit)
    {page_rows, length(rows) > limit}
  end

  defp list_items_for_turns(_db, _thread_id, []), do: []

  defp list_items_for_turns(db, thread_id, turns) do
    turn_ids = Enum.map(turns, & &1["id"])
    placeholders = Enum.map_join(turn_ids, ",", fn _id -> "?" end)

    db
    |> SQLite.all!(
      """
      SELECT items.*, turns.status AS turn_status, turns.user_text AS turn_user_text
           , turns.model AS turn_model, turns.effort AS turn_effort
           , turns.approval_policy AS turn_approval_policy
           , turns.sandbox_mode AS turn_sandbox_mode
           , turns.data_provider AS turn_data_provider
           , turns.agent_harness AS turn_agent_harness
           , turns.remote_model AS turn_remote_model
           , turns.created_at AS turn_created_at, turns.updated_at AS turn_updated_at
           , turns.completed_at AS turn_completed_at, turns.error AS turn_error
      FROM items
      LEFT JOIN turns ON turns.id = items.turn_id
      WHERE items.thread_id = ?
        AND items.turn_id IN (#{placeholders})
        AND items.invalidated_at IS NULL
        AND COALESCE(turns.invalidated_at, '') = ''
      ORDER BY turns.created_at ASC, turns.id ASC, items.created_at ASC, items.id ASC
      """,
      [thread_id | turn_ids]
    )
    |> Enum.map(&decode_item/1)
  end

  defp latest_turn_id(db, thread_id) do
    SQLite.scalar!(
      db,
      """
      SELECT id
      FROM turns
      WHERE thread_id = ?
        AND invalidated_at IS NULL
      ORDER BY created_at DESC, id DESC
      LIMIT 1
      """,
      [thread_id]
    )
  end

  defp turn_cursor(nil), do: nil

  defp turn_cursor(turn) do
    %{
      created_at: turn["created_at"],
      id: turn["id"]
    }
  end

  defp placeholders(values), do: Enum.map_join(values, ",", fn _value -> "?" end)

  defp reference_payload(reference_assets, nil, nil), do: %{asset_ids: reference_assets}

  defp reference_payload(reference_assets, mask_edit, data_provider) do
    %{asset_ids: reference_assets}
    |> maybe_put_payload_value(:mask_edit, mask_edit)
    |> maybe_put_payload_value(:data_provider, data_provider)
  end

  defp maybe_put_payload_value(payload, _key, nil), do: payload
  defp maybe_put_payload_value(payload, _key, ""), do: payload
  defp maybe_put_payload_value(payload, key, value), do: Map.put(payload, key, value)

  defp decode_item(nil), do: nil

  defp decode_item(item) do
    payload =
      case item["payload"] do
        nil -> %{}
        "" -> %{}
        payload -> Jason.decode!(payload)
      end

    item
    |> Map.put("payload", payload)
    |> decode_embedded_json("turn_data_provider")
  end

  defp decode_turn(nil), do: nil

  defp decode_turn(turn) do
    decode_embedded_json(turn, "data_provider")
  end

  defp decode_embedded_json(row, key) do
    case Map.get(row, key) do
      nil ->
        row

      "" ->
        Map.put(row, key, nil)

      value when is_binary(value) ->
        case Jason.decode(value) do
          {:ok, decoded} -> Map.put(row, key, decoded)
          {:error, _reason} -> row
        end

      _value ->
        row
    end
  end

  defp encode_optional_json(nil), do: nil
  defp encode_optional_json(""), do: nil
  defp encode_optional_json(value), do: Jason.encode!(value)

  defp attr(attrs, key) when is_list(attrs), do: Keyword.get(attrs, key)

  defp attr(attrs, key) when is_map(attrs) do
    Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))
  end

  defp with_project_db(project, fun) when is_function(fun, 1) do
    with {:ok, _meta} <- Avcs.Projects.ensure_project_db(project) do
      SQLite.with_db(Avcs.Projects.project_db_path(project), fun)
    end
  end

  defp item_trace_snapshot(nil), do: nil

  defp item_trace_snapshot(item) do
    %{
      id: item["id"],
      turn_id: item["turn_id"],
      thread_id: item["thread_id"],
      remote_item_id: item["remote_item_id"],
      tool_name: item["tool_name"],
      type: item["type"],
      role: item["role"],
      status: item["status"],
      content: content_snapshot(item["content"]),
      payload_keys: payload_keys(item["payload"])
    }
  end

  defp content_snapshot(nil), do: nil

  defp content_snapshot(content) do
    content = to_string(content)

    %{
      preview: String.slice(content, 0, 240),
      size_bytes: byte_size(content),
      sha256: :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
    }
  end

  defp payload_keys(payload) when is_map(payload) do
    payload
    |> Map.keys()
    |> Enum.map(&to_string/1)
    |> Enum.sort()
  end

  defp payload_keys(_payload), do: []

  defp trace_turn_update?(nil, _turn, _status, _remote_turn_id, _error), do: false

  defp trace_turn_update?(existing, turn, _status, remote_turn_id, error) do
    existing["status"] != turn["status"] or
      (is_binary(remote_turn_id) and remote_turn_id != "" and
         existing["remote_turn_id"] != turn["remote_turn_id"]) or
      not is_nil(error)
  end

  defp turn_event_name(existing, turn) do
    if existing && existing["status"] != turn["status"] do
      "turn_status_changed"
    else
      "turn_updated"
    end
  end
end
