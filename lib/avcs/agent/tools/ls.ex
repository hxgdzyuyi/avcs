defmodule Avcs.Agent.Tools.Ls do
  @moduledoc false

  @behaviour Avcs.Agent.Tool

  alias Avcs.Agent.Tools.ProjectFile

  @default_limit 100
  @max_limit 1_000

  @impl true
  def name, do: "ls"

  @impl true
  def description do
    "List files and directories inside the current Avcs project. Excludes .avcs and inaccessible paths; recursive listing never follows symlink directories."
  end

  @impl true
  def parameters_schema do
    %{
      "type" => "object",
      "properties" => %{
        "path" => %{"type" => "string"},
        "recursive" => %{"type" => "boolean"},
        "limit" => %{"type" => "integer", "minimum" => 1, "maximum" => @max_limit}
      }
    }
  end

  @impl true
  def normalize_arguments(arguments, _context) do
    with {:ok, arguments} <- ProjectFile.decode_arguments(arguments) do
      {:ok,
       %{
         path: ProjectFile.string_arg(arguments, "path", "."),
         recursive: ProjectFile.boolean_arg(arguments, "recursive", false),
         limit: ProjectFile.integer_arg(arguments, "limit", @default_limit, 1, @max_limit)
       }}
    end
  end

  @impl true
  def authorize(args, context) do
    with {:ok, _info} <-
           ProjectFile.resolve_existing(ProjectFile.value(context, :project), args.path,
             kind: :directory
           ) do
      :ok
    end
  end

  @impl true
  def execute(args, context) do
    project = ProjectFile.value(context, :project)

    with {:ok, info} <- ProjectFile.resolve_existing(project, args.path, kind: :directory),
         {:ok, result} <-
           ProjectFile.list_entries(project, info,
             recursive: args.recursive,
             limit: args.limit
           ) do
      {:ok,
       %{
         "status" => "completed",
         "path" => info.path,
         "relative_path" => info.relative_path,
         "truncated" => result.truncated,
         "entries" => Enum.map(result.entries, &ProjectFile.entry_result/1)
       }}
    end
  end
end
