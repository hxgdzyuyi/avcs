defmodule Avcs.Projects do
  @moduledoc """
  Project folder initialization and global index management.
  """

  alias Avcs.Storage.SQLite

  @schema_version "5"
  @project_sqlite_optimized_meta_key "project_sqlite_optimized_at"
  @project_sqlite_row_tables ~w(threads turns items assets board_items asset_links trace_events)

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
    case current_project() do
      %{} = project ->
        refresh_current_project(project)

      nil ->
        with {:ok, true} <- Avcs.SiteSettings.get_setting("projects.restore_last_opened"),
             {:ok, projects} <- list_projects(),
             %{"id" => id} <- Enum.find(projects, &(&1["status"] == "available")) do
          select_project(id)
        else
          false -> {:ok, nil}
          {:ok, false} -> {:ok, nil}
          nil -> {:ok, nil}
          {:error, reason} -> {:error, reason}
        end
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
        ORDER BY sidebar_order ASC, id ASC
        """)
        |> Enum.map(&enrich_project_index/1)
      end)
    end
  end

  def reorder_projects(project_ids) when is_list(project_ids) do
    with {:ok, _} <- migrate_global_db(),
         {:ok, normalized_ids} <- normalize_reordered_ids(project_ids) do
      SQLite.with_db(global_db_path(), fn db ->
        case validate_reorder_projects(db, normalized_ids) do
          :ok ->
            SQLite.transaction!(db, fn ->
              normalized_ids
              |> Enum.with_index()
              |> Enum.each(fn {project_id, index} ->
                SQLite.run!(db, "UPDATE projects SET sidebar_order = ? WHERE id = ?", [
                  index,
                  project_id
                ])
              end)
            end)

            {:ok, list_projects_from_connection(db)}

          {:error, reason} ->
            {:error, reason}
        end
      end)
      |> unwrap_sqlite_result()
    end
  end

  def reorder_projects(_project_ids) do
    {:error, :invalid_reorder_payload}
  end

  defp list_projects_from_connection(db) do
    db
    |> SQLite.all!("""
    SELECT *
    FROM projects
    WHERE archived_at IS NULL
    ORDER BY sidebar_order ASC, id ASC
    """)
    |> Enum.map(&enrich_project_index/1)
  end

  defp validate_reorder_projects(db, ordered_ids) do
    projects = SQLite.all!(db, "SELECT * FROM projects WHERE archived_at IS NULL")
    count_ok? = length(projects) == length(ordered_ids)
    ids_lookup = Map.new(projects, &{&1["id"], &1})
    all_ids_exist? = Enum.all?(ordered_ids, &Map.has_key?(ids_lookup, &1))

    unavailable_project? =
      all_ids_exist? &&
        Enum.any?(ordered_ids, fn id ->
          project = Map.fetch!(ids_lookup, id)
          not File.dir?(project["folder_path"]) or not File.exists?(project["project_db_path"])
        end)

    cond do
      !count_ok? ->
        {:error, :invalid_reorder_payload}

      !all_ids_exist? ->
        {:error, :project_not_found}

      unavailable_project? ->
        {:error, :project_unavailable}

      true ->
        :ok
    end
  end

  defp unwrap_sqlite_result({:ok, {:ok, result}}), do: {:ok, result}
  defp unwrap_sqlite_result({:ok, {:error, reason}}), do: {:error, reason}
  defp unwrap_sqlite_result(result), do: result

  defp normalize_reordered_ids(project_ids) do
    cleaned =
      project_ids
      |> Enum.map(&normalize_reorder_id/1)
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&String.trim/1)
      |> Enum.filter(&(&1 != ""))

    cond do
      length(cleaned) == 0 ->
        {:error, :invalid_reorder_payload}

      length(cleaned) != length(project_ids) ->
        {:error, :invalid_reorder_payload}

      length(cleaned) != length(Enum.uniq(cleaned)) ->
        {:error, :invalid_reorder_payload}

      true ->
        {:ok, cleaned}
    end
  end

  defp normalize_reorder_id(value) when is_binary(value), do: value
  defp normalize_reorder_id(_value), do: nil

  defp maybe_seed_project_sidebar_order(db) do
    if need_sidebar_order_seed?(db, "projects", "archived_at IS NULL") do
      SQLite.all!(db, "SELECT * FROM projects WHERE archived_at IS NULL")
      |> Enum.map(&enrich_project_index/1)
      |> sort_projects()
      |> Enum.with_index()
      |> Enum.each(fn {project, index} ->
        SQLite.run!(db, "UPDATE projects SET sidebar_order = ? WHERE id = ?", [
          index,
          project["id"]
        ])
      end)

      :ok
    else
      :ok
    end
  end

  defp maybe_seed_thread_sidebar_order(db) do
    if need_sidebar_order_seed?(db, "threads", "archived_at IS NULL") do
      SQLite.all!(
        db,
        "SELECT * FROM threads WHERE archived_at IS NULL ORDER BY created_at DESC, id DESC"
      )
      |> Enum.with_index()
      |> Enum.each(fn {thread, index} ->
        SQLite.run!(db, "UPDATE threads SET sidebar_order = ? WHERE id = ?", [
          index,
          thread["id"]
        ])
      end)

      :ok
    else
      :ok
    end
  end

  defp need_sidebar_order_seed?(db, table, where_clause) do
    total =
      SQLite.scalar!(db, "SELECT COUNT(*) FROM #{table} WHERE #{where_clause}")
      |> to_integer_or_zero()

    distinct =
      SQLite.scalar!(
        db,
        "SELECT COUNT(DISTINCT COALESCE(sidebar_order, -1)) FROM #{table} WHERE #{where_clause}"
      )
      |> to_integer_or_zero()

    total > 1 and total != distinct
  end

  defp to_integer_or_zero(nil), do: 0
  defp to_integer_or_zero(value) when is_integer(value), do: value
  defp to_integer_or_zero(value) when is_binary(value), do: parse_integer_or_zero(value)
  defp to_integer_or_zero(value) when is_float(value), do: trunc(value)
  defp to_integer_or_zero(_value), do: 0

  defp parse_integer_or_zero(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _ -> 0
    end
  end

  def get_project(id) when is_binary(id) do
    with {:ok, _} <- migrate_global_db(),
         {:ok, project} <- fetch_global_project(id) do
      {:ok, enrich_project_index(project)}
    end
  end

  def rename_project(id, name) when is_binary(id) do
    with {:ok, clean_name} <- clean_project_display_name(name),
         {:ok, _} <- migrate_global_db(),
         {:ok, _project} <- fetch_global_project(id),
         {:ok, renamed_project} <-
           SQLite.with_db(global_db_path(), fn db ->
             now = Avcs.Time.now_iso()

             SQLite.run!(
               db,
               "UPDATE projects SET name = ?, updated_at = ? WHERE id = ?",
               [clean_name, now, id]
             )

             SQLite.one!(db, "SELECT * FROM projects WHERE id = ? LIMIT 1", [id])
           end) do
      renamed_project =
        renamed_project
        |> enrich_project_index()
        |> sync_current_project_after_rename()

      broadcast_projects_updated()
      {:ok, renamed_project}
    else
      {:error, "Project not found"} -> {:error, :project_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def rename_project(_id, _name), do: {:error, :project_not_found}

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
        sidebar_order INTEGER NOT NULL DEFAULT 0,
        archived_at TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        last_opened_at TEXT NOT NULL
      );
      """)

      Avcs.SiteSettings.ensure_table!(db)
      ensure_column(db, "projects", "archived_at", "TEXT")
      ensure_column(db, "projects", "sidebar_order", "INTEGER NOT NULL DEFAULT 0")
      maybe_seed_project_sidebar_order(db)
    end)
  end

  def project_db_path(project), do: project["project_db_path"] || project[:project_db_path]
  def folder_path(project), do: project["folder_path"] || project[:folder_path]

  def ensure_project_db(nil), do: {:error, :no_project}

  def ensure_project_db(project) when is_map(project) do
    with :ok <- ensure_project_dirs(folder_path(project)) do
      migrate_project_db(project)
    end
  end

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

  def project_sqlite_info(project \\ current_project())

  def project_sqlite_info(nil), do: {:error, :no_project}

  def project_sqlite_info(project) when is_map(project) do
    db_path = project_db_path(project)
    exists? = is_binary(db_path) and File.exists?(db_path)
    status = project_sqlite_status(project, exists?)

    base_info = %{
      project_id: project_id(project),
      db_path: db_path,
      exists: exists?,
      size_bytes: 0,
      file_mtime: nil,
      status: status,
      sqlite_info: %{},
      table_rows: [],
      optimized_at: nil
    }

    cond do
      !exists? ->
        {:ok, base_info}

      true ->
        with {:ok, stat} <- File.stat(db_path, time: :posix),
             {:ok, sqlite_data} <-
               SQLite.with_db(db_path, fn db ->
                 %{
                   sqlite_info: read_project_sqlite_pragmas(db),
                   table_rows: read_project_sqlite_table_rows(db),
                   optimized_at: read_project_meta(db, @project_sqlite_optimized_meta_key)
                 }
               end) do
          {:ok,
           Map.merge(base_info, %{
             size_bytes: stat.size,
             file_mtime: DateTime.from_unix!(stat.mtime) |> DateTime.to_iso8601(),
             status: "available",
             sqlite_info: sqlite_data.sqlite_info,
             table_rows: sqlite_data.table_rows,
             optimized_at: sqlite_data.optimized_at
           })}
        else
          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  def project_sqlite_maintenance(action) do
    project_sqlite_maintenance(current_project(), action, [])
  end

  def project_sqlite_maintenance(project, action) do
    project_sqlite_maintenance(project, action, [])
  end

  def project_sqlite_maintenance(nil, _action, _opts), do: {:error, :no_project}

  def project_sqlite_maintenance(project, action, opts) when is_map(project) do
    with {:ok, action} <- normalize_project_sqlite_action(action),
         :ok <- ensure_project_sqlite_available(project) do
      if action == "deep_vacuum" and Keyword.get(opts, :async, true) do
        start_async_project_sqlite_maintenance(project, action)
      else
        run_sync_project_sqlite_maintenance(project, action)
      end
    end
  end

  defp start_async_project_sqlite_maintenance(project, action) do
    job = project_sqlite_job(project, action)
    parent = self()

    case Task.Supervisor.start_child(Avcs.Agent.TaskSupervisor, fn ->
           case register_project_sqlite_maintenance(job) do
             :ok ->
               send(parent, {:project_sqlite_maintenance_registered, job.job_id})
               execute_project_sqlite_maintenance(project, job)

             {:error, :project_sqlite_maintenance_running} ->
               send(parent, {:project_sqlite_maintenance_duplicate, job.job_id})
           end
         end) do
      {:ok, _pid} ->
        receive do
          {:project_sqlite_maintenance_registered, job_id} when job_id == job.job_id ->
            {:ok, %{status: "running", job_id: job.job_id}}

          {:project_sqlite_maintenance_duplicate, job_id} when job_id == job.job_id ->
            {:error, :project_sqlite_maintenance_running}
        after
          1_000 ->
            {:ok, %{status: "running", job_id: job.job_id}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp run_sync_project_sqlite_maintenance(project, action) do
    job = project_sqlite_job(project, action)

    with :ok <- register_project_sqlite_maintenance(job) do
      try do
        case execute_project_sqlite_maintenance(project, job) do
          {:ok, details} ->
            {:ok,
             %{
               status: "completed",
               job_id: job.job_id,
               details: details
             }}

          {:error, reason} ->
            {:error, reason}
        end
      after
        Registry.unregister(
          Avcs.Agent.RunnerRegistry,
          project_sqlite_maintenance_key(job.project_id)
        )
      end
    end
  end

  defp execute_project_sqlite_maintenance(project, job) do
    started_at = System.monotonic_time(:millisecond)

    Avcs.Events.broadcast("project:sqlite:maintenance_started", %{
      project_id: job.project_id,
      job_id: job.job_id,
      action: job.action,
      status: "running"
    })

    result = do_project_sqlite_maintenance(project, job.action)
    elapsed_ms = System.monotonic_time(:millisecond) - started_at

    details =
      case result do
        :ok ->
          %{duration_ms: elapsed_ms}

        {:error, reason} ->
          %{
            duration_ms: elapsed_ms,
            error_code: project_sqlite_maintenance_error_code(reason),
            error_message: to_string(reason)
          }
      end

    Avcs.Events.broadcast("project:sqlite:maintenance_completed", %{
      project_id: job.project_id,
      job_id: job.job_id,
      action: job.action,
      success: result == :ok,
      elapsed_ms: elapsed_ms,
      details: details
    })

    case result do
      :ok -> {:ok, details}
      {:error, reason} -> {:error, reason}
    end
  end

  defp do_project_sqlite_maintenance(project, "fast_optimize") do
    SQLite.with_db(project_db_path(project), fn db ->
      SQLite.all!(db, "PRAGMA wal_checkpoint(TRUNCATE)")
      SQLite.all!(db, "PRAGMA optimize")
      write_project_sqlite_optimized_at(db)
      :ok
    end)
    |> case do
      {:ok, :ok} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp do_project_sqlite_maintenance(project, "deep_vacuum") do
    SQLite.with_db(project_db_path(project), fn db ->
      SQLite.exec!(db, "VACUUM")
      write_project_sqlite_optimized_at(db)
      :ok
    end)
    |> case do
      {:ok, :ok} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp project_sqlite_job(project, action) do
    %{
      job_id: Ecto.UUID.generate(),
      project_id: project_id(project),
      action: action
    }
  end

  defp register_project_sqlite_maintenance(job) do
    case Registry.register(
           Avcs.Agent.RunnerRegistry,
           project_sqlite_maintenance_key(job.project_id),
           job
         ) do
      {:ok, _owner} -> :ok
      {:error, {:already_registered, _pid}} -> {:error, :project_sqlite_maintenance_running}
    end
  end

  defp project_sqlite_maintenance_key(project_id) do
    {:project_sqlite_maintenance, project_id}
  end

  defp normalize_project_sqlite_action(action) when action in ["fast_optimize", "deep_vacuum"] do
    {:ok, action}
  end

  defp normalize_project_sqlite_action(:fast_optimize), do: {:ok, "fast_optimize"}
  defp normalize_project_sqlite_action(:deep_vacuum), do: {:ok, "deep_vacuum"}
  defp normalize_project_sqlite_action(_action), do: {:error, :invalid_project_sqlite_action}

  defp ensure_project_sqlite_available(project) do
    cond do
      not File.dir?(folder_path(project)) ->
        {:error, :project_folder_missing}

      not File.exists?(project_db_path(project)) ->
        {:error, :project_sqlite_unavailable}

      true ->
        :ok
    end
  end

  defp project_sqlite_status(project, exists?) do
    cond do
      not File.dir?(folder_path(project)) -> "missing"
      exists? -> "available"
      true -> "unavailable"
    end
  end

  defp read_project_sqlite_pragmas(db) do
    journal_mode = SQLite.scalar!(db, "PRAGMA journal_mode")

    %{
      page_size: to_integer_or_zero(SQLite.scalar!(db, "PRAGMA page_size")),
      page_count: to_integer_or_zero(SQLite.scalar!(db, "PRAGMA page_count")),
      freelist_count: to_integer_or_zero(SQLite.scalar!(db, "PRAGMA freelist_count")),
      wal_mode: to_string(journal_mode || ""),
      schema_version:
        read_project_meta(db, "schema_version") ||
          to_string(SQLite.scalar!(db, "PRAGMA schema_version") || ""),
      journal_mode: journal_mode,
      foreign_keys: to_integer_or_zero(SQLite.scalar!(db, "PRAGMA foreign_keys"))
    }
  end

  defp read_project_sqlite_table_rows(db) do
    existing_tables =
      db
      |> SQLite.all!("SELECT name FROM sqlite_master WHERE type = 'table'")
      |> MapSet.new(& &1["name"])

    @project_sqlite_row_tables
    |> Enum.filter(&MapSet.member?(existing_tables, &1))
    |> Enum.map(fn table ->
      %{
        name: table,
        rows: to_integer_or_zero(SQLite.scalar!(db, "SELECT COUNT(*) FROM #{table}"))
      }
    end)
  end

  defp read_project_meta(db, key) do
    row = SQLite.one!(db, "SELECT value FROM project_meta WHERE key = ? LIMIT 1", [key])
    row && row["value"]
  end

  defp write_project_sqlite_optimized_at(db) do
    now = Avcs.Time.now_iso()
    upsert_meta(db, @project_sqlite_optimized_meta_key, now, now)
  end

  defp project_sqlite_maintenance_error_code(:project_folder_missing),
    do: "project_folder_missing"

  defp project_sqlite_maintenance_error_code(:project_sqlite_unavailable),
    do: "project_sqlite_unavailable"

  defp project_sqlite_maintenance_error_code(:invalid_project_sqlite_action),
    do: "invalid_project_sqlite_action"

  defp project_sqlite_maintenance_error_code(_reason),
    do: "project_sqlite_maintenance_failed"

  defp project_id(project), do: project["id"] || project[:id]

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

  defp refresh_current_project(project) do
    with :ok <- ensure_project_dirs(folder_path(project)),
         {:ok, _meta} <- migrate_project_db(project),
         {:ok, current_thread_id} <- default_thread_id(project) do
      project =
        project
        |> enrich_project_index()
        |> Map.put("current_thread_id", current_thread_id)

      :ok = Avcs.Session.set_current_project(project)
      {:ok, project}
    end
  end

  defp clear_current_project_if_removed(id) do
    case current_project() do
      %{"id" => ^id} -> Avcs.Session.set_current_project(nil)
      _project -> :ok
    end
  end

  defp sync_current_project_after_rename(%{"id" => id} = renamed_project) do
    case current_project() do
      %{"id" => ^id} = current_project ->
        renamed_project =
          Map.put(
            renamed_project,
            "current_thread_id",
            current_project["current_thread_id"]
          )

        :ok = Avcs.Session.set_current_project(renamed_project)
        Avcs.Events.broadcast("project:updated", %{project: renamed_project})
        renamed_project

      _project ->
        renamed_project
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

  defp clean_project_display_name(raw_name) when is_binary(raw_name) do
    case clean_project_name(raw_name) do
      {:ok, name} -> {:ok, name}
      {:error, _reason} -> {:error, :invalid_project_name}
    end
  end

  defp clean_project_display_name(_raw_name), do: {:error, :invalid_project_name}

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
            SET project_db_path = ?, archived_at = NULL, updated_at = ?, last_opened_at = ?, sidebar_order = COALESCE(sidebar_order, 0)
            WHERE id = ?
            """,
            [project_db_path, now, now, id]
          )
        else
          sidebar_order = next_project_sidebar_order(db)

          SQLite.run!(
            db,
            """
            INSERT INTO projects
              (id, name, folder_path, project_db_path, sidebar_order, created_at, updated_at, last_opened_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [id, name, folder_path, project_db_path, sidebar_order, now, now, now]
          )
        end

        SQLite.one!(db, "SELECT * FROM projects WHERE id = ? LIMIT 1", [id])
      end)
    end
  end

  defp next_project_sidebar_order(db) do
    SQLite.scalar!(
      db,
      "SELECT COALESCE(MIN(sidebar_order) - 1, 0) FROM projects WHERE archived_at IS NULL"
    ) || 0
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
        sidebar_order INTEGER NOT NULL DEFAULT 0,
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
        data_provider TEXT,
        completed_at TEXT,
        error TEXT,
        invalidated_at TEXT,
        invalidated_by_item_id TEXT,
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
        invalidated_at TEXT,
        invalidated_by_item_id TEXT,
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
        invalidated_at TEXT,
        invalidated_by_item_id TEXT,
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
        invalidated_at TEXT,
        invalidated_by_item_id TEXT,
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

      ensure_column(db, "threads", "sidebar_order", "INTEGER NOT NULL DEFAULT 0")
      maybe_seed_thread_sidebar_order(db)

      ensure_column(db, "turns", "model", "TEXT")
      ensure_column(db, "turns", "effort", "TEXT")
      ensure_column(db, "turns", "approval_policy", "TEXT")
      ensure_column(db, "turns", "sandbox_mode", "TEXT")
      ensure_column(db, "turns", "data_provider", "TEXT")
      ensure_column(db, "turns", "completed_at", "TEXT")
      ensure_column(db, "turns", "error", "TEXT")
      ensure_column(db, "turns", "invalidated_at", "TEXT")
      ensure_column(db, "turns", "invalidated_by_item_id", "TEXT")
      ensure_column(db, "items", "codex_item_id", "TEXT")
      ensure_column(db, "items", "invalidated_at", "TEXT")
      ensure_column(db, "items", "invalidated_by_item_id", "TEXT")
      ensure_column(db, "asset_links", "invalidated_at", "TEXT")
      ensure_column(db, "asset_links", "invalidated_by_item_id", "TEXT")
      ensure_column(db, "board_items", "invalidated_at", "TEXT")
      ensure_column(db, "board_items", "invalidated_by_item_id", "TEXT")

      SQLite.exec!(
        db,
        """
        CREATE INDEX IF NOT EXISTS idx_items_codex_item_id ON items(codex_item_id);
        CREATE INDEX IF NOT EXISTS idx_turns_invalidated
          ON turns(thread_id, invalidated_at);
        CREATE INDEX IF NOT EXISTS idx_items_invalidated
          ON items(thread_id, invalidated_at);
        CREATE INDEX IF NOT EXISTS idx_board_items_invalidated
          ON board_items(thread_id, invalidated_at);
        """
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
