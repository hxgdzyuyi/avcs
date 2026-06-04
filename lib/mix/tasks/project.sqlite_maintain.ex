defmodule Mix.Tasks.Project.SqliteMaintain do
  @moduledoc """
  Runs SQLite maintenance for a local Avcs project folder.

  Usage:
    mix project.sqlite_maintain /absolute/project/folder --action fast_optimize
    mix project.sqlite_maintain /absolute/project/folder --action deep_vacuum
  """

  use Mix.Task

  @shortdoc "Run project SQLite maintenance"
  @actions ~w(fast_optimize deep_vacuum)

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    {project_folder, action} = parse_args(args)

    with {:ok, project} <- Avcs.Projects.open_project(project_folder),
         {:ok, result} <- Avcs.Projects.project_sqlite_maintenance(project, action, async: false) do
      Mix.shell().info(Jason.encode!(result, pretty: true))
    else
      {:error, reason} -> Mix.raise(to_string(reason))
    end
  end

  defp parse_args(args) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: [action: :string])

    if invalid != [] do
      Mix.raise("invalid option: #{inspect(invalid)}")
    end

    action = opts[:action]

    unless action in @actions do
      Mix.raise("action must be fast_optimize or deep_vacuum")
    end

    case rest do
      [project_folder] ->
        path = Path.expand(project_folder)

        unless Path.type(path) == :absolute do
          Mix.raise("project_folder must be an absolute path: #{project_folder}")
        end

        {path, action}

      _other ->
        Mix.raise("""
        invalid args

        Usage:
          mix project.sqlite_maintain <project_folder> --action fast_optimize|deep_vacuum
        """)
    end
  end
end
