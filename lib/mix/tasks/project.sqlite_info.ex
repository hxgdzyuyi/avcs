defmodule Mix.Tasks.Project.SqliteInfo do
  @moduledoc """
  Prints SQLite information for a local Avcs project folder.

  Usage:
    mix project.sqlite_info /absolute/project/folder
  """

  use Mix.Task

  @shortdoc "Print project SQLite information"

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    project_folder = parse_args(args)

    with {:ok, project} <- Avcs.Projects.open_project(project_folder),
         {:ok, info} <- Avcs.Projects.project_sqlite_info(project) do
      Mix.shell().info(Jason.encode!(info, pretty: true))
    else
      {:error, reason} -> Mix.raise(to_string(reason))
    end
  end

  defp parse_args([project_folder]) do
    path = Path.expand(project_folder)

    unless Path.type(path) == :absolute do
      Mix.raise("project_folder must be an absolute path: #{project_folder}")
    end

    path
  end

  defp parse_args(_args) do
    Mix.raise("""
    invalid args

    Usage:
      mix project.sqlite_info <project_folder>
    """)
  end
end
