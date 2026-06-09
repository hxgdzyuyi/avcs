defmodule Avcs.Agent.Tools.Find do
  @moduledoc false

  @behaviour Avcs.Agent.Tool

  alias Avcs.Agent.Tools.ProjectFile

  @default_limit 100
  @max_limit 1_000

  @impl true
  def name, do: "find"

  @impl true
  def description do
    "Find files by filename text or glob inside the current Avcs project. Does not scan .avcs or follow project-external symlinks."
  end

  @impl true
  def parameters_schema do
    %{
      "type" => "object",
      "properties" => %{
        "path" => %{"type" => "string"},
        "pattern" => %{"type" => "string"},
        "limit" => %{"type" => "integer", "minimum" => 1, "maximum" => @max_limit}
      },
      "required" => ["pattern"]
    }
  end

  @impl true
  def normalize_arguments(arguments, _context) do
    with {:ok, arguments} <- ProjectFile.decode_arguments(arguments) do
      pattern = ProjectFile.string_arg(arguments, "pattern")

      if is_binary(pattern) do
        {:ok,
         %{
           path: ProjectFile.string_arg(arguments, "path", "."),
           pattern: pattern,
           limit: ProjectFile.integer_arg(arguments, "limit", @default_limit, 1, @max_limit)
         }}
      else
        {:error, ProjectFile.error(:pattern_required, "find requires a pattern")}
      end
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
           ProjectFile.list_entries(project, info, recursive: true, limit: args.limit * 10) do
      matches =
        result.entries
        |> Enum.filter(&(&1.type == :regular))
        |> Enum.filter(fn entry ->
          ProjectFile.glob_match?(entry.relative_path, Path.basename(entry.path), args.pattern)
        end)
        |> Enum.take(args.limit)
        |> Enum.map(fn entry ->
          %{
            "name" => Path.basename(entry.path),
            "path" => entry.path,
            "relative_path" => entry.relative_path,
            "size" => entry.size,
            "mtime" => ProjectFile.entry_result(entry)["mtime"]
          }
        end)

      {:ok,
       %{
         "status" => "completed",
         "path" => info.path,
         "relative_path" => info.relative_path,
         "truncated" => result.truncated or length(matches) >= args.limit,
         "files" => matches
       }}
    end
  end
end
