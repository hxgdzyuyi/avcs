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
      SQLite.all!(
        db,
        """
        SELECT *
        FROM threads
        WHERE archived_at IS NULL
        ORDER BY updated_at DESC, created_at DESC
        """
      )
    end)
  end

  def get_thread(project, id) do
    SQLite.with_db(Avcs.Projects.project_db_path(project), fn db ->
      SQLite.one!(db, "SELECT * FROM threads WHERE id = ? LIMIT 1", [id])
    end)
  end

  def create_thread(project, title \\ "Untitled thread") do
    SQLite.with_db(Avcs.Projects.project_db_path(project), fn db ->
      now = Avcs.Time.now_iso()
      id = Ecto.UUID.generate()

      SQLite.run!(
        db,
        """
        INSERT INTO threads (id, title, created_at, updated_at)
        VALUES (?, ?, ?, ?)
        """,
        [id, clean_title(title), now, now]
      )

      SQLite.one!(db, "SELECT * FROM threads WHERE id = ? LIMIT 1", [id])
    end)
  end

  def rename_thread(project, id, title) do
    SQLite.with_db(Avcs.Projects.project_db_path(project), fn db ->
      now = Avcs.Time.now_iso()

      SQLite.run!(
        db,
        "UPDATE threads SET title = ?, updated_at = ? WHERE id = ?",
        [clean_title(title), now, id]
      )

      SQLite.one!(db, "SELECT * FROM threads WHERE id = ? LIMIT 1", [id])
    end)
  end

  def archive_thread(project, id) do
    SQLite.with_db(Avcs.Projects.project_db_path(project), fn db ->
      now = Avcs.Time.now_iso()

      SQLite.run!(db, "UPDATE threads SET archived_at = ?, updated_at = ? WHERE id = ?", [
        now,
        now,
        id
      ])

      :ok
    end)
  end

  def set_codex_thread_id(project, id, codex_thread_id) do
    SQLite.with_db(Avcs.Projects.project_db_path(project), fn db ->
      SQLite.run!(
        db,
        "UPDATE threads SET codex_thread_id = ?, updated_at = ? WHERE id = ?",
        [codex_thread_id, Avcs.Time.now_iso(), id]
      )

      :ok
    end)
  end

  def update_settings(project, id, attrs) do
    settings = clean_settings(attrs)

    SQLite.with_db(Avcs.Projects.project_db_path(project), fn db ->
      now = Avcs.Time.now_iso()

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

  defp value(attrs, key) when is_map(attrs) do
    Map.get(attrs, key) || Map.get(attrs, String.to_atom(key))
  end

  defp value(attrs, key) when is_list(attrs), do: Keyword.get(attrs, String.to_atom(key))
  defp value(_attrs, _key), do: nil
end
