defmodule Avcs.Turns do
  @moduledoc false

  alias Avcs.Storage.SQLite

  def list_items(project, thread_id) do
    SQLite.with_db(Avcs.Projects.project_db_path(project), fn db ->
      SQLite.all!(
        db,
        """
        SELECT items.*, turns.status AS turn_status, turns.user_text AS turn_user_text
             , turns.model AS turn_model, turns.effort AS turn_effort
             , turns.approval_policy AS turn_approval_policy
             , turns.sandbox_mode AS turn_sandbox_mode
             , turns.created_at AS turn_created_at, turns.updated_at AS turn_updated_at
             , turns.completed_at AS turn_completed_at, turns.error AS turn_error
        FROM items
        LEFT JOIN turns ON turns.id = items.turn_id
        WHERE items.thread_id = ?
        ORDER BY items.created_at ASC
        """,
        [thread_id]
      )
      |> Enum.map(&decode_item/1)
    end)
  end

  def create_user_turn(project, thread_id, text, reference_assets, opts \\ []) do
    SQLite.with_db(Avcs.Projects.project_db_path(project), fn db ->
      SQLite.transaction!(db, fn ->
        now = Avcs.Time.now_iso()
        turn_id = Ecto.UUID.generate()
        item_id = Ecto.UUID.generate()
        payload = Jason.encode!(%{asset_ids: reference_assets})
        model = attr(opts, :model)
        effort = attr(opts, :effort)
        approval_policy = attr(opts, :approval_policy) || "never"
        sandbox_mode = attr(opts, :sandbox_mode) || "workspace-write"

        SQLite.run!(
          db,
          """
          INSERT INTO turns (
            id, thread_id, status, user_text, model, effort, approval_policy,
            sandbox_mode, created_at, updated_at
          )
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          """,
          [
            turn_id,
            thread_id,
            "in_progress",
            text,
            model,
            effort,
            approval_policy,
            sandbox_mode,
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

        %{
          "turn" => SQLite.one!(db, "SELECT * FROM turns WHERE id = ?", [turn_id]),
          "item" => decode_item(SQLite.one!(db, "SELECT * FROM items WHERE id = ?", [item_id]))
        }
      end)
    end)
  end

  def list_turns(project, thread_id) do
    SQLite.with_db(Avcs.Projects.project_db_path(project), fn db ->
      SQLite.all!(
        db,
        """
        SELECT *
        FROM turns
        WHERE thread_id = ?
        ORDER BY created_at ASC
        """,
        [thread_id]
      )
    end)
  end

  def append_item(project, attrs) do
    SQLite.with_db(Avcs.Projects.project_db_path(project), fn db ->
      now = Avcs.Time.now_iso()
      id = attr(attrs, :id) || Ecto.UUID.generate()
      type = attr(attrs, :type)
      thread_id = attr(attrs, :thread_id)
      turn_id = attr(attrs, :turn_id)
      codex_item_id = attr(attrs, :codex_item_id)
      role = attr(attrs, :role)
      content = attr(attrs, :content)
      status = attr(attrs, :status) || "completed"
      payload = attr(attrs, :payload) || %{}

      SQLite.run!(
        db,
        """
        INSERT INTO items (
          id, turn_id, thread_id, codex_item_id, type, role, content, payload,
          status, created_at, updated_at
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        [
          id,
          turn_id,
          thread_id,
          codex_item_id,
          type,
          role,
          content,
          Jason.encode!(payload),
          status,
          now,
          now
        ]
      )

      decode_item(SQLite.one!(db, "SELECT * FROM items WHERE id = ?", [id]))
    end)
  end

  def upsert_codex_item(project, attrs) do
    SQLite.with_db(Avcs.Projects.project_db_path(project), fn db ->
      SQLite.transaction!(db, fn ->
        now = Avcs.Time.now_iso()
        thread_id = attr(attrs, :thread_id)
        turn_id = attr(attrs, :turn_id)
        codex_item_id = attr(attrs, :codex_item_id)
        type = attr(attrs, :type)
        role = attr(attrs, :role)
        content = attr(attrs, :content)
        status = attr(attrs, :status) || "completed"
        payload = attr(attrs, :payload) || %{}

        existing =
          if codex_item_id do
            SQLite.one!(
              db,
              """
              SELECT * FROM items
              WHERE thread_id = ? AND turn_id = ? AND codex_item_id = ?
              LIMIT 1
              """,
              [thread_id, turn_id, codex_item_id]
            )
          end

        if existing do
          SQLite.run!(
            db,
            """
            UPDATE items
            SET type = ?, role = ?, content = ?, payload = ?, status = ?, updated_at = ?
            WHERE id = ?
            """,
            [type, role, content, Jason.encode!(payload), status, now, existing["id"]]
          )

          decode_item(SQLite.one!(db, "SELECT * FROM items WHERE id = ?", [existing["id"]]))
        else
          id = attr(attrs, :id) || Ecto.UUID.generate()

          SQLite.run!(
            db,
            """
            INSERT INTO items (
              id, turn_id, thread_id, codex_item_id, type, role, content, payload,
              status, created_at, updated_at
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [
              id,
              turn_id,
              thread_id,
              codex_item_id,
              type,
              role,
              content,
              Jason.encode!(payload),
              status,
              now,
              now
            ]
          )

          decode_item(SQLite.one!(db, "SELECT * FROM items WHERE id = ?", [id]))
        end
      end)
    end)
  end

  def get_approval_item(project, thread_id, turn_id, review_id) do
    case SQLite.with_db(Avcs.Projects.project_db_path(project), fn db ->
           db
           |> SQLite.one!(
             """
             SELECT * FROM items
             WHERE thread_id = ?
               AND turn_id = ?
               AND codex_item_id = ?
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
    case SQLite.with_db(Avcs.Projects.project_db_path(project), fn db ->
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

               decode_item(SQLite.one!(db, "SELECT * FROM items WHERE id = ?", [id]))
             end
           end)
         end) do
      {:ok, nil} -> {:error, :not_found}
      {:ok, item} -> {:ok, item}
      error -> error
    end
  end

  def complete_turn(project, turn_id, codex_turn_id \\ nil) do
    update_turn_status(project, turn_id, "completed", codex_turn_id, nil)
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

  def update_turn_status(project, turn_id, status, codex_turn_id, error \\ nil) do
    SQLite.with_db(Avcs.Projects.project_db_path(project), fn db ->
      now = Avcs.Time.now_iso()
      completed_at = if status in ["completed", "failed"], do: now

      SQLite.run!(
        db,
        """
        UPDATE turns
        SET status = ?,
            codex_turn_id = COALESCE(?, codex_turn_id),
            completed_at = COALESCE(?, completed_at),
            error = COALESCE(?, error),
            updated_at = ?
        WHERE id = ?
        """,
        [status, codex_turn_id, completed_at, error, now, turn_id]
      )

      SQLite.one!(db, "SELECT * FROM turns WHERE id = ?", [turn_id])
    end)
  end

  defp decode_item(nil), do: nil

  defp decode_item(item) do
    payload =
      case item["payload"] do
        nil -> %{}
        "" -> %{}
        payload -> Jason.decode!(payload)
      end

    Map.put(item, "payload", payload)
  end

  defp attr(attrs, key) when is_list(attrs), do: Keyword.get(attrs, key)

  defp attr(attrs, key) when is_map(attrs) do
    Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))
  end
end
