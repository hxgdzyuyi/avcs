defmodule Avcs.Projects do
  @moduledoc """
  Project folder initialization and global index management.
  """

  alias Avcs.Storage.SQLite

  @schema_version "2"

  def global_db_path do
    Application.get_env(:avcs, :global_db_path) ||
      Path.join([System.user_home!(), ".avcs", "avcs.sqlite3"])
  end

  def blank_projects_dir do
    Application.get_env(:avcs, :blank_projects_dir) ||
      case Avcs.SiteSettings.get_setting("projects.default_root") do
        {:ok, path} -> path
        {:error, _reason} -> default_blank_projects_dir()
      end
  end

  def default_blank_projects_dir do
    Path.join([System.user_home!(), "Documents", "Avcs"])
  end

  def current_project, do: Avcs.Session.current_project()

  def restore_last_opened_project do
    with nil <- current_project(),
         {:ok, true} <- Avcs.SiteSettings.get_setting("projects.restore_last_opened"),
         {:ok, projects} <- list_projects(),
         %{"id" => id} <- Enum.find(projects, &(&1["status"] == "available")) do
      select_project(id)
    else
      %{} = project -> {:ok, project}
      false -> {:ok, nil}
      {:ok, false} -> {:ok, nil}
      nil -> {:ok, nil}
      {:error, reason} -> {:error, reason}
    end
  end

  def list_projects do
    with {:ok, _} <- migrate_global_db() do
      SQLite.with_db(global_db_path(), fn db ->
        db
        |> SQLite.all!("""
        SELECT *
        FROM projects
        WHERE archived_at IS NULL
        ORDER BY name ASC
        """)
        |> Enum.map(&enrich_project_index/1)
        |> sort_projects()
      end)
    end
  end

  def get_project(id) when is_binary(id) do
    with {:ok, _} <- migrate_global_db(),
         {:ok, project} <- fetch_global_project(id) do
      {:ok, enrich_project_index(project)}
    end
  end

  def archive_project(id) when is_binary(id) do
    with {:ok, _} <- migrate_global_db(),
         {:ok, _project} <- fetch_global_project(id, include_archived: true),
         {:ok, archived_project} <-
           SQLite.with_db(global_db_path(), fn db ->
             now = Avcs.Time.now_iso()

             SQLite.run!(
               db,
               "UPDATE projects SET archived_at = ?, updated_at = ? WHERE id = ?",
               [now, now, id]
             )

             SQLite.one!(db, "SELECT * FROM projects WHERE id = ? LIMIT 1", [id])
           end) do
      clear_current_project_if_removed(id)
      Avcs.Events.broadcast("project:updated", %{project: current_project()})
      broadcast_projects_updated()
      {:ok, enrich_project_index(archived_project)}
    end
  end

  def delete_project_reference(id) when is_binary(id) do
    with {:ok, _} <- migrate_global_db(),
         {:ok, project} <- fetch_global_project(id, include_archived: true),
         {:ok, :ok} <-
           SQLite.with_db(global_db_path(), fn db ->
             SQLite.run!(db, "DELETE FROM projects WHERE id = ?", [id])
             :ok
           end) do
      clear_current_project_if_removed(id)
      Avcs.Events.broadcast("project:updated", %{project: current_project()})
      broadcast_projects_updated()
      {:ok, project}
    end
  end

  def create_blank_project(name) when is_binary(name) do
    with {:ok, clean_name} <- clean_project_name(name) do
      blank_projects_dir()
      |> unique_blank_project_path(clean_name)
      |> open_project()
    end
  end

  def open_project(path) when is_binary(path) do
    with {:ok, folder_path} <- normalize_project_path(path),
         :ok <- ensure_project_dirs(folder_path),
         {:ok, project} <- upsert_global_project(folder_path),
         {:ok, _meta} <- migrate_project_db(project),
         {:ok, current_thread_id} <- default_thread_id(project) do
      project =
        project
        |> enrich_project_index()
        |> Map.put("current_thread_id", current_thread_id)

      :ok = Avcs.Session.set_current_project(project)
      Avcs.Events.broadcast("project:updated", %{project: project})
      broadcast_projects_updated()
      maybe_scan_project_on_open(project)
      {:ok, project}
    end
  end

  def select_project(id) when is_binary(id) do
    with {:ok, project} <- get_project(id),
         :ok <- ensure_indexed_project_available(project),
         :ok <- ensure_project_dirs(folder_path(project)),
         {:ok, _meta} <- migrate_project_db(project),
         {:ok, current_thread_id} <- default_thread_id(project) do
      project =
        project
        |> enrich_project_index()
        |> Map.put("current_thread_id", current_thread_id)

      :ok = Avcs.Session.set_current_project(project)
      Avcs.Events.broadcast("project:updated", %{project: project})
      maybe_scan_project_on_open(project)
      {:ok, project}
    end
  end

  def migrate_global_db do
    SQLite.with_db(global_db_path(), fn db ->
      SQLite.exec!(db, """
      CREATE TABLE IF NOT EXISTS projects (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        folder_path TEXT NOT NULL UNIQUE,
        project_db_path TEXT NOT NULL,
        archived_at TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        last_opened_at TEXT NOT NULL
      );
      """)

      Avcs.SiteSettings.ensure_table!(db)
      ensure_column(db, "projects", "archived_at", "TEXT")
    end)
  end

  def project_db_path(project), do: project["project_db_path"] || project[:project_db_path]
  def folder_path(project), do: project["folder_path"] || project[:folder_path]

  def output_dir(project), do: Path.join(folder_path(project), "output")
  def work_dir(project), do: Path.join(folder_path(project), "work")

  def relative_to_project(project, path) do
    folder = folder_path(project) |> Path.expand()
    expanded = Path.expand(path)

    if inside?(expanded, folder) do
      {:ok, Path.relative_to(expanded, folder)}
    else
      {:error, :outside_project}
    end
  end

  def resolve_project_path(project, relative_or_absolute) do
    folder = folder_path(project) |> Path.expand()
    path = Path.expand(relative_or_absolute, folder)

    if inside?(path, folder) do
      {:ok, path}
    else
      {:error, :outside_project}
    end
  end

  def inside?(path, root) do
    path = Path.expand(path)
    root = Path.expand(root)
    path == root or String.starts_with?(path, root <> "/")
  end

  def broadcast_projects_updated do
    case list_projects() do
      {:ok, projects} -> Avcs.Events.broadcast("projects:updated", %{items: projects})
      {:error, _reason} -> :ok
    end
  end

  defp fetch_global_project(id, opts \\ []) do
    include_archived = Keyword.get(opts, :include_archived, false)
    archived_filter = if include_archived, do: "", else: "AND archived_at IS NULL"

    SQLite.with_db(global_db_path(), fn db ->
      SQLite.one!(
        db,
        "SELECT * FROM projects WHERE id = ? #{archived_filter} LIMIT 1",
        [id]
      )
    end)
    |> case do
      {:ok, nil} -> {:error, "Project not found"}
      {:ok, project} -> {:ok, project}
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_indexed_project_available(project) do
    cond do
      not File.dir?(folder_path(project)) ->
        {:error, "Project folder is unavailable. Reopen the folder to repair this project."}

      not File.exists?(project_db_path(project)) ->
        {:error, "Project database is unavailable. Reopen the folder to repair this project."}

      true ->
        :ok
    end
  end

  defp enrich_project_index(nil), do: nil

  defp enrich_project_index(project) do
    status =
      cond do
        not File.dir?(folder_path(project)) -> "missing"
        not File.exists?(project_db_path(project)) -> "unavailable"
        true -> "available"
      end

    Map.merge(project, %{
      "status" => status,
      "last_activity_at" => last_thread_activity(project) || project["last_opened_at"]
    })
  end

  defp sort_projects(projects) do
    Enum.sort(projects, &project_order_before?/2)
  end

  defp project_order_before?(first, second) do
    first_time = project_sort_time(first)
    second_time = project_sort_time(second)
    first_name = project_sort_name(first)
    second_name = project_sort_name(second)
    first_id = to_string(first["id"] || "")
    second_id = to_string(second["id"] || "")

    cond do
      first_time != second_time -> first_time > second_time
      first_name != second_name -> first_name < second_name
      true -> first_id < second_id
    end
  end

  defp project_sort_time(project) do
    to_string(project["last_activity_at"] || project["last_opened_at"] || "")
  end

  defp project_sort_name(project) do
    project["name"]
    |> to_string()
    |> String.downcase()
  end

  defp last_thread_activity(project) do
    db_path = project_db_path(project)

    if db_path && File.exists?(db_path) do
      case SQLite.with_db(db_path, fn db ->
             SQLite.scalar!(db, "SELECT MAX(updated_at) FROM threads WHERE archived_at IS NULL")
           end) do
        {:ok, value} -> value
        {:error, _reason} -> nil
      end
    end
  end

  defp default_thread_id(project) do
    case Avcs.Threads.list_threads(project) do
      {:ok, [thread | _threads]} -> {:ok, thread["id"]}
      {:ok, []} -> {:ok, nil}
      {:error, reason} -> {:error, reason}
    end
  end

  defp clear_current_project_if_removed(id) do
    case current_project() do
      %{"id" => ^id} -> Avcs.Session.set_current_project(nil)
      _project -> :ok
    end
  end

  defp maybe_scan_project_on_open(project) do
    case Avcs.SiteSettings.get_setting("assets.scan_on_open") do
      {:ok, true} ->
        case Avcs.Assets.scan_project(project) do
          {:ok, _assets} ->
            broadcast_assets_and_board(project)

          {:error, reason} ->
            Avcs.Events.broadcast("error", %{
              message: "Asset scan failed: #{to_string(reason)}"
            })
        end

      _other ->
        :ok
    end
  end

  defp broadcast_assets_and_board(project) do
    with {:ok, assets} <- Avcs.Assets.list_assets(project),
         {:ok, board_items} <- Avcs.Board.list_items(project) do
      Avcs.Events.broadcast("assets:updated", %{items: assets})
      Avcs.Events.broadcast("board:items", %{items: board_items})
    end

    :ok
  end

  defp ensure_column(db, table, column, definition) do
    columns = SQLite.all!(db, "PRAGMA table_info(#{table})")

    unless Enum.any?(columns, &(&1["name"] == column)) do
      SQLite.exec!(db, "ALTER TABLE #{table} ADD COLUMN #{column} #{definition}")
    end
  end

  defp normalize_project_path(raw_path) do
    path =
      raw_path
      |> String.trim()
      |> Path.expand()

    cond do
      path == "" ->
        {:error, "Project path is required"}

      Path.type(path) != :absolute ->
        {:error, "Project path must be absolute"}

      File.exists?(path) and not File.dir?(path) ->
        {:error, "Project path points to a file, not a folder"}

      true ->
        case File.mkdir_p(path) do
          :ok -> {:ok, path}
          {:error, reason} -> {:error, "Cannot create project folder: #{inspect(reason)}"}
        end
    end
  end

  defp clean_project_name(raw_name) do
    name = String.trim(raw_name)

    cond do
      name == "" ->
        {:error, "Project name is required"}

      name in [".", ".."] or String.contains?(name, ["/", "\\"]) ->
        {:error, "Project name cannot contain path separators"}

      true ->
        {:ok, name}
    end
  end

  defp unique_blank_project_path(root, name) do
    root = Path.expand(root)

    Stream.iterate(1, &(&1 + 1))
    |> Enum.reduce_while(nil, fn index, _acc ->
      candidate_name = if index == 1, do: name, else: "#{name} #{index}"
      candidate_path = Path.join(root, candidate_name)

      if File.exists?(candidate_path) do
        {:cont, nil}
      else
        {:halt, candidate_path}
      end
    end)
  end

  defp ensure_project_dirs(folder_path) do
    [
      Path.join([folder_path, ".avcs", "cache", "thumbnails"]),
      Path.join([folder_path, ".avcs", "cache", "temp"]),
      Path.join(folder_path, "work"),
      Path.join(folder_path, "output")
    ]
    |> Enum.reduce_while(:ok, fn dir, :ok ->
      case File.mkdir_p(dir) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, "Cannot create #{dir}: #{inspect(reason)}"}}
      end
    end)
  end

  defp upsert_global_project(folder_path) do
    with {:ok, _} <- migrate_global_db() do
      SQLite.with_db(global_db_path(), fn db ->
        now = Avcs.Time.now_iso()
        project_db_path = Path.join([folder_path, ".avcs", "project.sqlite3"])
        name = Path.basename(folder_path)

        existing =
          SQLite.one!(
            db,
            "SELECT * FROM projects WHERE folder_path = ? LIMIT 1",
            [folder_path]
          )

        id = if existing, do: existing["id"], else: Ecto.UUID.generate()

        if existing do
          SQLite.run!(
            db,
            """
            UPDATE projects
            SET name = ?, project_db_path = ?, archived_at = NULL, updated_at = ?, last_opened_at = ?
            WHERE id = ?
            """,
            [name, project_db_path, now, now, id]
          )
        else
          SQLite.run!(
            db,
            """
            INSERT INTO projects
              (id, name, folder_path, project_db_path, created_at, updated_at, last_opened_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            [id, name, folder_path, project_db_path, now, now, now]
          )
        end

        SQLite.one!(db, "SELECT * FROM projects WHERE id = ? LIMIT 1", [id])
      end)
    end
  end

  defp migrate_project_db(project) do
    SQLite.with_db(project_db_path(project), fn db ->
      SQLite.exec!(db, """
      CREATE TABLE IF NOT EXISTS project_meta (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL,
        updated_at TEXT NOT NULL
      );

      CREATE TABLE IF NOT EXISTS threads (
        id TEXT PRIMARY KEY,
        title TEXT NOT NULL,
        codex_thread_id TEXT,
        status TEXT NOT NULL DEFAULT 'idle',
        default_model TEXT,
        default_effort TEXT,
        default_approval_policy TEXT NOT NULL DEFAULT 'never',
        default_sandbox_mode TEXT NOT NULL DEFAULT 'workspace-write',
        archived_at TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      );

      CREATE TABLE IF NOT EXISTS turns (
        id TEXT PRIMARY KEY,
        thread_id TEXT NOT NULL,
        codex_turn_id TEXT,
        status TEXT NOT NULL,
        user_text TEXT,
        model TEXT,
        effort TEXT,
        approval_policy TEXT,
        sandbox_mode TEXT,
        completed_at TEXT,
        error TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        FOREIGN KEY(thread_id) REFERENCES threads(id)
      );

      CREATE TABLE IF NOT EXISTS items (
        id TEXT PRIMARY KEY,
        turn_id TEXT,
        thread_id TEXT NOT NULL,
        codex_item_id TEXT,
        type TEXT NOT NULL,
        role TEXT,
        content TEXT,
        payload TEXT,
        status TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        FOREIGN KEY(turn_id) REFERENCES turns(id),
        FOREIGN KEY(thread_id) REFERENCES threads(id)
      );

      CREATE TABLE IF NOT EXISTS assets (
        id TEXT PRIMARY KEY,
        file_path TEXT NOT NULL,
        relative_path TEXT NOT NULL,
        file_name TEXT NOT NULL,
        file_type TEXT NOT NULL,
        mime_type TEXT NOT NULL,
        width INTEGER,
        height INTEGER,
        size_bytes INTEGER NOT NULL,
        hash TEXT NOT NULL UNIQUE,
        source TEXT NOT NULL,
        prompt TEXT,
        thread_id TEXT,
        turn_id TEXT,
        item_id TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      );

      CREATE TABLE IF NOT EXISTS asset_links (
        id TEXT PRIMARY KEY,
        asset_id TEXT NOT NULL,
        thread_id TEXT,
        turn_id TEXT,
        item_id TEXT,
        source TEXT NOT NULL,
        created_at TEXT NOT NULL,
        FOREIGN KEY(asset_id) REFERENCES assets(id)
      );

      CREATE TABLE IF NOT EXISTS board_items (
        id TEXT PRIMARY KEY,
        asset_id TEXT NOT NULL UNIQUE,
        thread_id TEXT,
        turn_id TEXT,
        item_id TEXT,
        x REAL NOT NULL,
        y REAL NOT NULL,
        display_width REAL NOT NULL,
        display_height REAL NOT NULL,
        z_index INTEGER NOT NULL,
        source TEXT NOT NULL,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        FOREIGN KEY(asset_id) REFERENCES assets(id)
      );

      CREATE TABLE IF NOT EXISTS trace_events (
        id TEXT PRIMARY KEY,
        scope TEXT NOT NULL,
        event_name TEXT NOT NULL,
        thread_id TEXT NOT NULL,
        turn_id TEXT,
        item_id TEXT,
        codex_thread_id TEXT,
        codex_turn_id TEXT,
        codex_item_id TEXT,
        status TEXT,
        payload TEXT,
        raw TEXT,
        omitted TEXT,
        created_at TEXT NOT NULL
      );

      CREATE TABLE IF NOT EXISTS settings (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL,
        updated_at TEXT NOT NULL
      );

      CREATE INDEX IF NOT EXISTS idx_turns_thread_id ON turns(thread_id);
      CREATE INDEX IF NOT EXISTS idx_turns_thread_created_id
        ON turns(thread_id, created_at, id);
      CREATE INDEX IF NOT EXISTS idx_items_thread_id ON items(thread_id);
      CREATE INDEX IF NOT EXISTS idx_items_turn_created_id
        ON items(turn_id, created_at, id);
      CREATE INDEX IF NOT EXISTS idx_assets_thread_id ON assets(thread_id);
      CREATE INDEX IF NOT EXISTS idx_board_items_thread_id ON board_items(thread_id);
      CREATE INDEX IF NOT EXISTS idx_trace_events_thread_id
        ON trace_events(thread_id, created_at);
      CREATE INDEX IF NOT EXISTS idx_trace_events_turn_id
        ON trace_events(turn_id, created_at);
      CREATE INDEX IF NOT EXISTS idx_trace_events_codex_item_id
        ON trace_events(codex_item_id, created_at);
      """)

      ensure_column(db, "threads", "status", "TEXT NOT NULL DEFAULT 'idle'")
      ensure_column(db, "threads", "default_model", "TEXT")
      ensure_column(db, "threads", "default_effort", "TEXT")
      ensure_column(db, "threads", "default_approval_policy", "TEXT NOT NULL DEFAULT 'never'")

      ensure_column(
        db,
        "threads",
        "default_sandbox_mode",
        "TEXT NOT NULL DEFAULT 'workspace-write'"
      )

      ensure_column(db, "turns", "model", "TEXT")
      ensure_column(db, "turns", "effort", "TEXT")
      ensure_column(db, "turns", "approval_policy", "TEXT")
      ensure_column(db, "turns", "sandbox_mode", "TEXT")
      ensure_column(db, "turns", "completed_at", "TEXT")
      ensure_column(db, "turns", "error", "TEXT")
      ensure_column(db, "items", "codex_item_id", "TEXT")

      SQLite.exec!(
        db,
        "CREATE INDEX IF NOT EXISTS idx_items_codex_item_id ON items(codex_item_id);"
      )

      now = Avcs.Time.now_iso()

      upsert_meta(db, "project_id", project["id"], now)
      upsert_meta(db, "project_name", project["name"], now)
      upsert_meta(db, "schema_version", @schema_version, now)

      SQLite.all!(db, "SELECT * FROM project_meta ORDER BY key")
    end)
  end

  defp upsert_meta(db, key, value, now) do
    SQLite.run!(
      db,
      """
      INSERT INTO project_meta (key, value, updated_at)
      VALUES (?, ?, ?)
      ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at
      """,
      [key, value, now]
    )
  end
end
