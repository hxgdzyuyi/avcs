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
end
