defmodule Avcs.Agent.Tools.Read do
  @moduledoc false

  @behaviour Avcs.Agent.Tool

  alias Avcs.Agent.Tools.ProjectFile

  @default_limit 200
  @max_limit 2_000

  @impl true
  def name, do: "read"

  @impl true
  def description do
    "Read a UTF-8 text file inside the current Avcs project. Cannot read .avcs, SQLite, secret-like, binary, oversized, or project-external paths."
  end

  @impl true
  def parameters_schema do
    %{
      "type" => "object",
      "properties" => %{
        "path" => %{"type" => "string"},
        "offset" => %{"type" => "integer", "minimum" => 0},
        "limit" => %{"type" => "integer", "minimum" => 1, "maximum" => @max_limit}
      },
      "required" => ["path"]
    }
  end

  @impl true
  def normalize_arguments(arguments, _context) do
    with {:ok, arguments} <- ProjectFile.decode_arguments(arguments) do
      path = ProjectFile.string_arg(arguments, "path")

      if is_binary(path) do
        {:ok,
         %{
           path: path,
           offset: ProjectFile.integer_arg(arguments, "offset", 0, 0, 1_000_000),
           limit: ProjectFile.integer_arg(arguments, "limit", @default_limit, 1, @max_limit)
         }}
      else
        {:error, ProjectFile.error(:path_required, "read requires a path")}
      end
    end
  end

  @impl true
  def authorize(args, context) do
    with {:ok, _info} <-
           ProjectFile.resolve_existing(ProjectFile.value(context, :project), args.path,
             kind: :file
           ) do
      :ok
    end
  end

  @impl true
  def execute(args, context) do
    project = ProjectFile.value(context, :project)

    with {:ok, info} <- ProjectFile.resolve_existing(project, args.path, kind: :file),
         {:ok, text} <- ProjectFile.read_text(info) do
      lines = String.split(text, "\n", trim: false)
      selected = lines |> Enum.drop(args.offset) |> Enum.take(args.limit)
      truncated = args.offset + length(selected) < length(lines)

      {:ok,
       %{
         "status" => "completed",
         "content" => Enum.join(selected, "\n"),
         "path" => info.path,
         "relative_path" => info.relative_path,
         "size" => info.size,
         "truncated" => truncated
       }}
    end
  end
end
