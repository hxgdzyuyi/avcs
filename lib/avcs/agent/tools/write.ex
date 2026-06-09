defmodule Avcs.Agent.Tools.Write do
  @moduledoc false

  @behaviour Avcs.Agent.Tool

  alias Avcs.Agent.Tools.ProjectFile

  @encodings ["utf-8", "utf8", "base64"]
  @if_exists ["error", "overwrite"]

  @impl true
  def name, do: "write"

  @impl true
  def description do
    "Write a file in the current Avcs project work/ or output/ directory. Defaults to refusing overwrites and never writes .avcs, SQLite, secret-like, or project-external paths."
  end

  @impl true
  def parameters_schema do
    %{
      "type" => "object",
      "properties" => %{
        "path" => %{"type" => "string"},
        "content" => %{"type" => "string"},
        "encoding" => %{"type" => "string", "enum" => @encodings},
        "if_exists" => %{"type" => "string", "enum" => @if_exists}
      },
      "required" => ["path", "content"]
    }
  end

  @impl true
  def normalize_arguments(arguments, _context) do
    with {:ok, arguments} <- ProjectFile.decode_arguments(arguments) do
      path = ProjectFile.string_arg(arguments, "path")
      content = ProjectFile.value(arguments, "content")
      encoding = normalize_encoding(ProjectFile.string_arg(arguments, "encoding", "utf-8"))
      if_exists = normalize_if_exists(ProjectFile.string_arg(arguments, "if_exists", "error"))

      cond do
        not is_binary(path) ->
          {:error, ProjectFile.error(:path_required, "write requires a path")}

        not is_binary(content) ->
          {:error, ProjectFile.error(:content_required, "write requires string content")}

        is_nil(encoding) ->
          {:error, ProjectFile.error(:invalid_encoding, "write encoding must be utf-8 or base64")}

        is_nil(if_exists) ->
          {:error,
           ProjectFile.error(:invalid_if_exists, "write if_exists must be error or overwrite")}

        true ->
          {:ok, %{path: path, content: content, encoding: encoding, if_exists: if_exists}}
      end
    end
  end

  @impl true
  def authorize(args, context) do
    with {:ok, target} <-
           ProjectFile.resolve_target(ProjectFile.value(context, :project), args.path,
             scopes: [:work, :output]
           ),
         :ok <- ensure_overwrite_allowed(target, args.if_exists) do
      :ok
    end
  end

  @impl true
  def execute(args, context) do
    project = ProjectFile.value(context, :project)

    with {:ok, target} <-
           ProjectFile.resolve_target(project, args.path, scopes: [:work, :output]),
         :ok <- ensure_overwrite_allowed(target, args.if_exists),
         {:ok, bytes} <- decode_content(args),
         before_sha <- existing_sha(target),
         :ok <- ProjectFile.write_file(target, bytes),
         {:ok, info} <- ProjectFile.resolve_existing(project, target.path, kind: :file),
         sha <- ProjectFile.sha256(bytes),
         {:ok, asset} <- maybe_upsert_image(project, info, context) do
      {:ok,
       %{
         "status" => "completed",
         "path" => info.path,
         "relative_path" => info.relative_path,
         "size" => byte_size(bytes),
         "sha256_before" => before_sha,
         "sha256_after" => sha,
         "asset" => asset_summary(asset)
       }
       |> reject_blank_values()}
    end
  end

  defp normalize_encoding(value) when is_binary(value) do
    value = String.downcase(String.trim(value))
    if value in @encodings, do: value
  end

  defp normalize_encoding(_value), do: nil

  defp normalize_if_exists(value) when is_binary(value) do
    value = String.downcase(String.trim(value))
    if value in @if_exists, do: value
  end

  defp normalize_if_exists(_value), do: nil

  defp ensure_overwrite_allowed(%{exists?: true}, "error"),
    do: {:error, ProjectFile.error(:file_exists, "File already exists")}

  defp ensure_overwrite_allowed(_target, _if_exists), do: :ok

  defp decode_content(%{encoding: "base64", content: content}) do
    content
    |> String.replace(~r/\s+/, "")
    |> Base.decode64()
    |> case do
      {:ok, bytes} -> {:ok, bytes}
      :error -> {:error, ProjectFile.error(:invalid_base64, "write content is not valid base64")}
    end
  end

  defp decode_content(%{content: content}), do: {:ok, content}

  defp existing_sha(%{exists?: true, path: path}) do
    case File.read(path) do
      {:ok, bytes} -> ProjectFile.sha256(bytes)
      {:error, _reason} -> nil
    end
  end

  defp existing_sha(_target), do: nil

  defp maybe_upsert_image(project, info, context) do
    source =
      if String.starts_with?(info.relative_path, "output/") do
        "generated"
      else
        "agent_write"
      end

    ProjectFile.upsert_image_if_supported(project, info.path, context, source)
  end

  defp asset_summary(nil), do: nil

  defp asset_summary(asset) do
    %{
      "asset_id" => asset["id"],
      "relative_path" => asset["relative_path"],
      "hash" => asset["hash"],
      "mime_type" => asset["mime_type"],
      "width" => asset["width"],
      "height" => asset["height"]
    }
  end

  defp reject_blank_values(map) do
    map
    |> Enum.reject(fn {_key, value} -> value in [nil, "", [], %{}] end)
    |> Map.new()
  end
end
