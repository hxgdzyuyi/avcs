defmodule AvcsWeb.ProjectController do
  use AvcsWeb, :controller

  alias AvcsWeb.ApiResponse

  def create_blank(conn, %{"name" => name}) do
    case Avcs.Projects.create_blank_project(name) do
      {:ok, project} ->
        ApiResponse.ok(conn, project)

      {:error, reason} ->
        ApiResponse.error(conn, 422, "project_create_failed", to_string(reason))
    end
  end

  def create_blank(conn, _params) do
    ApiResponse.error(conn, 400, "missing_name", "Project name is required")
  end

  def open(conn, %{"path" => path}) do
    case Avcs.Projects.open_project(path) do
      {:ok, project} ->
        ApiResponse.ok(conn, project)

      {:error, reason} ->
        ApiResponse.error(conn, 422, "project_open_failed", to_string(reason))
    end
  end

  def open(conn, _params) do
    ApiResponse.error(conn, 400, "missing_path", "Project path is required")
  end

  def sqlite_info(conn, _params) do
    case Avcs.Projects.project_sqlite_info() do
      {:ok, info} ->
        ApiResponse.ok(conn, info)

      {:error, :no_project} ->
        ApiResponse.error(conn, 400, "no_project", "Open a project folder first")

      {:error, reason} ->
        ApiResponse.error(conn, 422, "project_sqlite_info_failed", to_string(reason))
    end
  end

  def sqlite_maintenance(conn, %{"action" => action}) do
    case Avcs.Projects.project_sqlite_maintenance(action) do
      {:ok, result} ->
        ApiResponse.ok(conn, result)

      {:error, :no_project} ->
        ApiResponse.error(conn, 400, "no_project", "Open a project folder first")

      {:error, :invalid_project_sqlite_action} ->
        ApiResponse.error(
          conn,
          400,
          "invalid_project_sqlite_action",
          "Action must be fast_optimize or deep_vacuum"
        )

      {:error, :project_sqlite_maintenance_running} ->
        ApiResponse.error(
          conn,
          409,
          "project_sqlite_maintenance_running",
          "Project SQLite maintenance is already running"
        )

      {:error, :project_folder_missing} ->
        ApiResponse.error(conn, 422, "project_folder_missing", "Project folder is unavailable")

      {:error, :project_sqlite_unavailable} ->
        ApiResponse.error(
          conn,
          422,
          "project_sqlite_unavailable",
          "Project SQLite database is unavailable"
        )

      {:error, reason} ->
        ApiResponse.error(conn, 422, "project_sqlite_maintenance_failed", to_string(reason))
    end
  end

  def sqlite_maintenance(conn, _params) do
    ApiResponse.error(conn, 400, "missing_action", "Maintenance action is required")
  end
end
