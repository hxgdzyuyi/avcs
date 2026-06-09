defmodule Avcs.Agent.Tools.Edit do
  @moduledoc false

  @behaviour Avcs.Agent.Tool

  alias Avcs.Agent.Tools.ProjectFile

  @max_preview_bytes 2_000

  @impl true
  def name, do: "edit"

  @impl true
  def description do
    "Edit a UTF-8 text file in the current Avcs project work/ directory by exact old_text replacement. Requires optional expected_sha256 to match when provided."
  end

  @impl true
  def parameters_schema do
    %{
      "type" => "object",
      "properties" => %{
        "path" => %{"type" => "string"},
        "old_text" => %{"type" => "string"},
        "new_text" => %{"type" => "string"},
        "occurrence" => %{
          "oneOf" => [
            %{"type" => "integer", "minimum" => 1},
            %{"type" => "string", "enum" => ["all"]}
          ]
        },
        "all" => %{"type" => "boolean"},
        "expected_sha256" => %{"type" => "string"}
      },
      "required" => ["path", "old_text", "new_text"]
    }
  end

  @impl true
  def normalize_arguments(arguments, _context) do
    with {:ok, arguments} <- ProjectFile.decode_arguments(arguments) do
      path = ProjectFile.string_arg(arguments, "path")
      old_text = ProjectFile.value(arguments, "old_text")
      new_text = ProjectFile.value(arguments, "new_text")

      cond do
        not is_binary(path) ->
          {:error, ProjectFile.error(:path_required, "edit requires a path")}

        not is_binary(old_text) or old_text == "" ->
          {:error, ProjectFile.error(:old_text_required, "edit requires non-empty old_text")}

        not is_binary(new_text) ->
          {:error, ProjectFile.error(:new_text_required, "edit requires new_text")}

        true ->
          {:ok,
           %{
             path: path,
             old_text: old_text,
             new_text: new_text,
             occurrence: normalize_occurrence(arguments),
             expected_sha256: ProjectFile.string_arg(arguments, "expected_sha256")
           }}
      end
    end
  end

  @impl true
  def authorize(args, context) do
    with {:ok, _info} <-
           ProjectFile.resolve_existing(ProjectFile.value(context, :project), args.path,
             kind: :file,
             scopes: [:work]
           ) do
      :ok
    end
  end

  @impl true
  def execute(args, context) do
    project = ProjectFile.value(context, :project)

    with {:ok, info} <-
           ProjectFile.resolve_existing(project, args.path, kind: :file, scopes: [:work]),
         {:ok, text} <- ProjectFile.read_text(info),
         sha_before = ProjectFile.sha256(text),
         :ok <- ensure_expected_sha(args.expected_sha256, sha_before),
         {:ok, updated} <- replace_text(text, args),
         :ok <- ProjectFile.write_file(info, updated),
         sha_after = ProjectFile.sha256(updated) do
      {:ok,
       %{
         "status" => "completed",
         "changed" => sha_before != sha_after,
         "path" => info.path,
         "relative_path" => info.relative_path,
         "sha256_before" => sha_before,
         "sha256_after" => sha_after,
         "preview" => preview(updated, args.new_text)
       }}
    end
  end

  defp normalize_occurrence(arguments) do
    cond do
      ProjectFile.boolean_arg(arguments, "all", false) ->
        :all

      ProjectFile.value(arguments, "occurrence") == "all" ->
        :all

      true ->
        ProjectFile.integer_arg(arguments, "occurrence", 1, 1, 1_000_000)
    end
  end

  defp ensure_expected_sha(nil, _sha), do: :ok
  defp ensure_expected_sha(expected, expected), do: :ok

  defp ensure_expected_sha(_expected, _sha),
    do: {:error, ProjectFile.error(:sha256_mismatch, "File sha256 did not match expected_sha256")}

  defp replace_text(text, %{occurrence: :all, old_text: old_text, new_text: new_text}) do
    if String.contains?(text, old_text) do
      {:ok, String.replace(text, old_text, new_text)}
    else
      {:error, ProjectFile.error(:old_text_not_found, "old_text was not found")}
    end
  end

  defp replace_text(text, %{occurrence: occurrence, old_text: old_text, new_text: new_text}) do
    parts = String.split(text, old_text)
    found = length(parts) - 1

    cond do
      found == 0 ->
        {:error, ProjectFile.error(:old_text_not_found, "old_text was not found")}

      occurrence > found ->
        {:error, ProjectFile.error(:occurrence_not_found, "Requested occurrence was not found")}

      true ->
        {left, [right | rest]} = Enum.split(parts, occurrence)

        {:ok,
         Enum.join(left, old_text) <>
           new_text <>
           Enum.join([right | rest], old_text)}
    end
  end

  defp preview(text, new_text) do
    case :binary.match(text, new_text) do
      {index, _length} ->
        start = max(index - 400, 0)
        String.slice(text, start, @max_preview_bytes)

      :nomatch ->
        String.slice(text, 0, @max_preview_bytes)
    end
  end
end
