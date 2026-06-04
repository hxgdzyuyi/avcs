defmodule Avcs.Threads do
  @moduledoc false

  alias Avcs.Storage.SQLite

  @valid_efforts ~w(none minimal low medium high xhigh)
  @valid_approval_policies ~w(never untrusted on-failure on-request)
  @valid_sandbox_modes ~w(read-only workspace-write danger-full-access)
  @untitled_thread_title "Untitled thread"
  @max_title_length 120

  def ensure_default(project) do
    case list_threads(project) do
      {:ok, [thread | _]} ->
        {:ok, thread}

      {:ok, []} ->
        create_thread(project, "Untitled thread")
    end
  end

  def list_threads(project) do
    SQLite.with_db(Avcs.Projects.project_db_path(project), fn db ->
      list_sidebar_threads(db)
    end)
  end

  def reorder_threads(project, ordered_ids) when is_list(ordered_ids) do
    SQLite.with_db(Avcs.Projects.project_db_path(project), fn db ->
      normalized_ids =
        ordered_ids
        |> Enum.map(&normalize_reorder_id/1)
        |> Enum.filter(&is_binary/1)
        |> Enum.map(&String.trim/1)
        |> Enum.filter(&(&1 != ""))

      with {:ok, ordered_thread_ids} <- validate_thread_reorder_payload(db, normalized_ids) do
        SQLite.transaction!(db, fn ->
          ordered_thread_ids
          |> Enum.with_index()
          |> Enum.each(fn {thread_id, index} ->
            SQLite.run!(db, "UPDATE threads SET sidebar_order = ? WHERE id = ?", [
              index,
              thread_id
            ])
          end)
        end)

        {:ok, list_sidebar_threads(db)}
      end
    end)
    |> unwrap_sqlite_result()
  end

  def reorder_threads(_project, _ordered_ids), do: {:error, :invalid_reorder_payload}

  def get_thread(project, id) do
    SQLite.with_db(Avcs.Projects.project_db_path(project), fn db ->
      SQLite.one!(db, "SELECT * FROM threads WHERE id = ? LIMIT 1", [id])
    end)
  end

  def create_thread(project, title \\ "Untitled thread") do
    SQLite.with_db(Avcs.Projects.project_db_path(project), fn db ->
      now = Avcs.Time.now_iso()
      id = Ecto.UUID.generate()
      title = clean_title(title)
      defaults = Avcs.SiteSettings.agent_defaults()
      sidebar_order = next_thread_sidebar_order(db)

      SQLite.run!(
        db,
        """
        INSERT INTO threads (
          id, title, default_model, default_effort, default_approval_policy,
          default_sandbox_mode, sidebar_order, created_at, updated_at
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        [
          id,
          title,
          defaults.model,
          defaults.effort,
          defaults.approval_policy,
          defaults.sandbox_mode,
          sidebar_order || 0,
          now,
          now
        ]
      )

      Avcs.Trace.append_event(
        project,
        %{
          scope: "thread",
          event_name: "thread_created",
          thread_id: id,
          status: "idle",
          payload: %{title: title, defaults: defaults}
        },
        db: db
      )

      SQLite.one!(db, "SELECT * FROM threads WHERE id = ? LIMIT 1", [id])
    end)
  end

  def rename_thread(project, id, title) do
    SQLite.with_db(Avcs.Projects.project_db_path(project), fn db ->
      now = Avcs.Time.now_iso()
      existing = SQLite.one!(db, "SELECT * FROM threads WHERE id = ? LIMIT 1", [id])
      title = clean_title(title)

      SQLite.run!(
        db,
        "UPDATE threads SET title = ?, updated_at = ? WHERE id = ?",
        [title, now, id]
      )

      if existing && existing["title"] != title do
        Avcs.Trace.append_event(
          project,
          %{
            scope: "thread",
            event_name: "thread_title_changed",
            thread_id: id,
            status: existing["status"],
            payload: %{from_title: existing["title"], to_title: title}
          },
          db: db
        )
      end

      SQLite.one!(db, "SELECT * FROM threads WHERE id = ? LIMIT 1", [id])
    end)
  end

  def archive_thread(project, id) do
    SQLite.with_db(Avcs.Projects.project_db_path(project), fn db ->
      now = Avcs.Time.now_iso()
      existing = SQLite.one!(db, "SELECT * FROM threads WHERE id = ? LIMIT 1", [id])

      SQLite.run!(db, "UPDATE threads SET archived_at = ?, updated_at = ? WHERE id = ?", [
        now,
        now,
        id
      ])

      if existing do
        Avcs.Trace.append_event(
          project,
          %{
            scope: "thread",
            event_name: "thread_archived",
            thread_id: id,
            status: existing["status"],
            payload: %{archived_at: now}
          },
          db: db
        )
      end

      :ok
    end)
  end

  def archive_all_threads(project) do
    SQLite.with_db(Avcs.Projects.project_db_path(project), fn db ->
      now = Avcs.Time.now_iso()

      existing =
        SQLite.all!(
          db,
          "SELECT * FROM threads WHERE archived_at IS NULL ORDER BY updated_at DESC, created_at DESC"
        )

      SQLite.run!(
        db,
        "UPDATE threads SET archived_at = ?, updated_at = ? WHERE archived_at IS NULL",
        [now, now]
      )

      Enum.each(existing, fn thread ->
        Avcs.Trace.append_event(
          project,
          %{
            scope: "thread",
            event_name: "thread_archived",
            thread_id: thread["id"],
            status: thread["status"],
            payload: %{archived_at: now}
          },
          db: db
        )
      end)

      %{
        archived_count: length(existing),
        archived_thread_ids: Enum.map(existing, & &1["id"])
      }
    end)
  end

  def set_codex_thread_id(project, id, codex_thread_id) do
    SQLite.with_db(Avcs.Projects.project_db_path(project), fn db ->
      existing = SQLite.one!(db, "SELECT * FROM threads WHERE id = ? LIMIT 1", [id])

      SQLite.run!(
        db,
        "UPDATE threads SET codex_thread_id = ?, updated_at = ? WHERE id = ?",
        [codex_thread_id, Avcs.Time.now_iso(), id]
      )

      if existing && existing["codex_thread_id"] != codex_thread_id do
        Avcs.Trace.append_event(
          project,
          %{
            scope: "thread",
            event_name: "thread_codex_id_bound",
            thread_id: id,
            codex_thread_id: codex_thread_id,
            status: existing["status"],
            payload: %{
              previous_codex_thread_id: existing["codex_thread_id"],
              codex_thread_id: codex_thread_id
            }
          },
          db: db
        )
      end

      :ok
    end)
  end

  def update_settings(project, id, attrs) do
    settings = clean_settings(attrs)

    SQLite.with_db(Avcs.Projects.project_db_path(project), fn db ->
      now = Avcs.Time.now_iso()
      existing = SQLite.one!(db, "SELECT * FROM threads WHERE id = ? LIMIT 1", [id])

      SQLite.run!(
        db,
        """
        UPDATE threads
        SET default_model = ?,
            default_effort = ?,
            default_approval_policy = ?,
            default_sandbox_mode = ?,
            updated_at = ?
        WHERE id = ?
        """,
        [
          settings.model,
          settings.effort,
          settings.approval_policy,
          settings.sandbox_mode,
          now,
          id
        ]
      )

      if trace_settings_update?(existing, settings) do
        Avcs.Trace.append_event(
          project,
          %{
            scope: "thread",
            event_name: "thread_settings_changed",
            thread_id: id,
            status: existing["status"],
            payload: %{
              from: thread_settings_snapshot(existing),
              to: settings
            }
          },
          db: db
        )
      end

      SQLite.one!(db, "SELECT * FROM threads WHERE id = ? LIMIT 1", [id])
    end)
  end

  def maybe_title_from_message(project, %{"id" => id, "title" => title} = thread, text) do
    if untitled_title?(title) do
      case suggest_title(text) do
        nil -> {:ok, thread}
        suggested_title -> rename_thread(project, id, suggested_title)
      end
    else
      {:ok, thread}
    end
  end

  def maybe_title_from_message(_project, thread, _text), do: {:ok, thread}

  def suggest_title(text) do
    case clean_optional_string(text) do
      nil -> nil
      value -> clean_title(value)
    end
  end

  defp validate_thread_reorder_payload(db, ordered_ids) do
    threads = SQLite.all!(db, "SELECT id FROM threads WHERE archived_at IS NULL")
    count_ok? = length(threads) == length(ordered_ids)
    ids_lookup = MapSet.new(Enum.map(threads, & &1["id"]))
    all_ids_exist? = Enum.all?(ordered_ids, &MapSet.member?(ids_lookup, &1))
    no_duplicates? = length(ordered_ids) == length(Enum.uniq(ordered_ids))

    cond do
      !no_duplicates? || length(ordered_ids) == 0 ->
        {:error, :invalid_reorder_payload}

      !count_ok? ->
        {:error, :invalid_reorder_payload}

      !all_ids_exist? ->
        {:error, :thread_not_found}

      true ->
        {:ok, ordered_ids}
    end
  end

  defp normalize_reorder_id(value) when is_binary(value), do: value
  defp normalize_reorder_id(_value), do: nil

  defp unwrap_sqlite_result({:ok, {:ok, result}}), do: {:ok, result}
  defp unwrap_sqlite_result({:ok, {:error, reason}}), do: {:error, reason}
  defp unwrap_sqlite_result(result), do: result

  defp list_sidebar_threads(db) do
    SQLite.all!(
      db,
      """
      SELECT *
      FROM threads
      WHERE archived_at IS NULL
      ORDER BY sidebar_order ASC, id ASC
      """
    )
  end

  defp next_thread_sidebar_order(db) do
    SQLite.scalar!(
      db,
      """
      SELECT COALESCE(MIN(sidebar_order) - 1, 0)
      FROM threads
      WHERE archived_at IS NULL
      """
    ) || 0
  end

  def touch(project, id) do
    SQLite.with_db(Avcs.Projects.project_db_path(project), fn db ->
      SQLite.run!(db, "UPDATE threads SET updated_at = ? WHERE id = ?", [Avcs.Time.now_iso(), id])
      :ok
    end)
  end

  def clean_settings(attrs) do
    %{
      model: clean_optional_string(value(attrs, "model")),
      effort: clean_member(value(attrs, "effort"), @valid_efforts),
      approval_policy:
        clean_member(value(attrs, "approval_policy"), @valid_approval_policies) || "never",
      sandbox_mode:
        clean_member(value(attrs, "sandbox_mode"), @valid_sandbox_modes) || "workspace-write"
    }
  end

  defp clean_title(title) do
    title
    |> to_string()
    |> String.trim()
    |> String.replace(~r/\s+/u, " ")
    |> case do
      "" -> @untitled_thread_title
      value -> String.slice(value, 0, @max_title_length)
    end
  end

  defp untitled_title?(title), do: clean_title(title) == @untitled_thread_title

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

  defp clean_member(value, valid_values) do
    value = clean_optional_string(value)
    if value in valid_values, do: value
  end

  defp trace_settings_update?(nil, _settings), do: false

  defp trace_settings_update?(existing, settings) do
    thread_settings_snapshot(existing) != settings
  end

  defp thread_settings_snapshot(thread) do
    %{
      model: thread["default_model"],
      effort: thread["default_effort"],
      approval_policy: thread["default_approval_policy"],
      sandbox_mode: thread["default_sandbox_mode"]
    }
  end

  defp value(attrs, key) when is_map(attrs) do
    Map.get(attrs, key) || Map.get(attrs, String.to_atom(key))
  end

  defp value(attrs, key) when is_list(attrs), do: Keyword.get(attrs, String.to_atom(key))
  defp value(_attrs, _key), do: nil
end
