defmodule Avcs.Agent.Tools.Grep do
  @moduledoc false

  @behaviour Avcs.Agent.Tool

  alias Avcs.Agent.Tools.ProjectFile

  @default_limit 100
  @max_limit 500
  @max_context_lines 5
  @timeout_ms 2_000

  @impl true
  def name, do: "grep"

  @impl true
  def description do
    "Search UTF-8 text files inside the current Avcs project using Avcs internal search. Does not call shell, scan .avcs, or read oversized/binary files."
  end

  @impl true
  def parameters_schema do
    %{
      "type" => "object",
      "properties" => %{
        "path" => %{"type" => "string"},
        "pattern" => %{"type" => "string"},
        "glob" => %{"type" => "string"},
        "case_sensitive" => %{"type" => "boolean"},
        "limit" => %{"type" => "integer", "minimum" => 1, "maximum" => @max_limit},
        "context_lines" => %{
          "type" => "integer",
          "minimum" => 0,
          "maximum" => @max_context_lines
        }
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
           glob: ProjectFile.string_arg(arguments, "glob"),
           case_sensitive: ProjectFile.boolean_arg(arguments, "case_sensitive", false),
           limit: ProjectFile.integer_arg(arguments, "limit", @default_limit, 1, @max_limit),
           context_lines:
             ProjectFile.integer_arg(arguments, "context_lines", 0, 0, @max_context_lines)
         }}
      else
        {:error, ProjectFile.error(:pattern_required, "grep requires a pattern")}
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

    with {:ok, regex} <- compile_regex(args),
         {:ok, info} <- ProjectFile.resolve_existing(project, args.path, kind: :directory),
         {:ok, result} <-
           ProjectFile.text_file_infos(project, info,
             limit: 2_000,
             timeout_ms: @timeout_ms
           ) do
      started_at = System.monotonic_time(:millisecond)
      {matches, timed_out?} = collect_matches(result.entries, args, regex, started_at, [])

      {:ok,
       %{
         "status" => "completed",
         "path" => info.path,
         "relative_path" => info.relative_path,
         "truncated" => result.truncated or timed_out? or length(matches) >= args.limit,
         "matches" => Enum.reverse(matches)
       }}
    end
  end

  defp compile_regex(%{pattern: pattern, case_sensitive: true}) do
    case Regex.compile(pattern) do
      {:ok, regex} ->
        {:ok, regex}

      {:error, reason} ->
        {:error, ProjectFile.error(:invalid_pattern, "grep pattern is invalid", inspect(reason))}
    end
  end

  defp compile_regex(%{pattern: pattern}) do
    case Regex.compile(pattern, "i") do
      {:ok, regex} ->
        {:ok, regex}

      {:error, reason} ->
        {:error, ProjectFile.error(:invalid_pattern, "grep pattern is invalid", inspect(reason))}
    end
  end

  defp collect_matches([], _args, _regex, _started_at, acc), do: {acc, false}

  defp collect_matches(_entries, args, _regex, _started_at, acc) when length(acc) >= args.limit,
    do: {acc, false}

  defp collect_matches([entry | rest], args, regex, started_at, acc) do
    cond do
      System.monotonic_time(:millisecond) - started_at > @timeout_ms ->
        {acc, true}

      not glob_allowed?(entry, args.glob) ->
        collect_matches(rest, args, regex, started_at, acc)

      true ->
        acc = file_matches(entry, args, regex, acc)
        collect_matches(rest, args, regex, started_at, acc)
    end
  end

  defp glob_allowed?(_entry, nil), do: true

  defp glob_allowed?(entry, glob) do
    ProjectFile.glob_match?(entry.relative_path, Path.basename(entry.path), glob)
  end

  defp file_matches(entry, args, regex, acc) do
    case ProjectFile.read_text(entry) do
      {:ok, text} ->
        lines = String.split(text, "\n", trim: false)

        lines
        |> Enum.with_index(1)
        |> Enum.reduce_while(acc, fn {line, line_number}, acc ->
          if length(acc) >= args.limit do
            {:halt, acc}
          else
            if Regex.match?(regex, line) do
              {:cont, [match_entry(entry, lines, line_number, line, args.context_lines) | acc]}
            else
              {:cont, acc}
            end
          end
        end)

      {:error, _reason} ->
        acc
    end
  end

  defp match_entry(entry, lines, line_number, line, context_lines) do
    before_start = max(line_number - context_lines - 1, 0)
    after_start = line_number

    %{
      "relative_path" => entry.relative_path,
      "line_number" => line_number,
      "line" => String.slice(line, 0, 500),
      "before" =>
        lines
        |> Enum.slice(before_start, line_number - before_start - 1)
        |> Enum.map(&String.slice(&1, 0, 500)),
      "after" =>
        lines
        |> Enum.slice(after_start, context_lines)
        |> Enum.map(&String.slice(&1, 0, 500))
    }
  end
end
