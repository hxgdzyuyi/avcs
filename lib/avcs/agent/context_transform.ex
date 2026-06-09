defmodule Avcs.Agent.ContextTransform do
  @moduledoc false

  @max_reference_image_bytes 8 * 1024 * 1024
  @max_history_reference_assets 6
  @max_board_items 30

  def build(project, thread_id, turn_id, text, reference_paths, opts \\ []) do
    with {:ok, current_refs} <- current_reference_assets(project, turn_id, reference_paths),
         {:ok, history} <- history_messages(project, thread_id, turn_id),
         {:ok, board_context} <- board_context(project),
         {:ok, system} <- system_message(project, opts, board_context) do
      current_user = user_message(text, current_refs, "user_item")

      {:ok,
       %{
         messages: [system] ++ history ++ [current_user],
         model_input_items:
           model_input_items(system, history, current_user, current_refs, board_context, opts),
         reference_assets: Enum.map(current_refs, &reference_asset_summary/1),
         board_context: board_context,
         data_provider_context: data_provider_context(opts),
         active_tools: active_tools(opts)
       }}
    end
  end

  def steer_user_message(project, text, reference_paths, opts \\ []) do
    with {:ok, refs} <- reference_assets_from_paths(project, reference_paths) do
      {:ok, user_message(text, refs, "queued_turn_input", opts)}
    end
  end

  defp system_message(project, opts, board_context) do
    skills = builtin_skills(opts)
    provider_context = data_provider_context(opts)

    content =
      [
        runtime_instructions(project),
        """
        AvcsAgent tool policy:
        - Use only Avcs-provided tools from the active tool whitelist.
        - Model-visible tool names follow pi-agent style (`read`, `write`, `edit`, `bash`, `grep`, `find`, `ls`), but each tool is an Avcs-native controlled backend tool, not open shell or filesystem access.
        - Do not request browser, MCP, arbitrary network, subagent, or multi-agent workflow tools.
        - `bash` is not a shell. It only accepts Avcs allowlisted command descriptors, currently built-in data providers.
        - File tools can only access the current Avcs project allowed scope and must never access `.avcs/`, SQLite, secret-like files, project-external paths, or symlink escapes.
        - `write` and `edit` are conservative tools and are available only when explicitly enabled for the turn.
        - Generated image files are saved by Avcs into the project output directory.
        - image_gen supports OpenAI-compatible image options including `size`, `quality`, `output_format`, `output_compression`, `background`, and `moderation`; visual `reference_asset_ids` and alpha-channel PNG `mask_asset_id` edits are available only when the configured image model transport supports references.
        """,
        skills_section(skills),
        provider_context && "Data provider context:\n#{Jason.encode!(provider_context)}",
        board_context_message(board_context)
      ]
      |> Enum.reject(&blank?/1)
      |> Enum.join("\n\n")

    {:ok,
     %{
       "role" => "system",
       "content" => content,
       "avcs_kind" => "system"
     }}
  end

  defp runtime_instructions(project) do
    path = Path.join(priv_dir(), "agent/thread-runtime-instructions.md")

    path
    |> File.read()
    |> case do
      {:ok, text} -> render_runtime_instructions(text, project)
      {:error, _reason} -> "Current project path: #{Avcs.Projects.folder_path(project)}"
    end
  end

  defp render_runtime_instructions(text, project) do
    skill_name = "avcs-imagegen-avcs-agent"
    skill_path = Path.join([priv_dir(), "skills", skill_name, "SKILL.md"])

    text
    |> String.replace("{{project_path}}", Avcs.Projects.folder_path(project))
    |> String.replace("{{project_output_dir}}", Avcs.Projects.output_dir(project))
    |> String.replace("{{avcs_imagegen_skill_name}}", skill_name)
    |> String.replace("{{avcs_imagegen_skill_path}}", skill_path)
    |> String.replace("{{image_gen_tool_policy}}", avcs_agent_image_gen_tool_policy())
  end

  defp avcs_agent_image_gen_tool_policy do
    """
    AvcsAgent image generation policy:
    - 当前 thread 中，图片生成只使用 Avcs 后端 `image_gen` tool。
    - AvcsAgent `image_gen` 支持文生图；仅当当前图片模型传输方式支持参考图时，才通过 `reference_asset_ids` 把当前项目图片资产作为视觉参考输入。
    - 当 data provider context 或 provider tool result 包含图片 `asset_id` 时，如果当前图片模型支持参考图则把该 id 放入 `reference_asset_ids`；如果当前模型只支持文生图，则把 provider 的标题、日期、说明、来源等摘要写入 prompt 后不传参考图。
    - 默认 Vercel AI Gateway 下，`openai/gpt-image-*`、DALL-E、Imagen、Flux 和 Grok image 等 image-only 模型走 `/images/generations` 文生图，不走 `/chat/completions` 参考图；Google Gemini image 等多模态图片输出模型按 Vercel 文档走 `/chat/completions`、`modalities: ["image"]`，有参考图时再用 data URL `image_url` 发送项目图片；非 Vercel OpenAI-compatible base URL 可走 `/images/edits`。
    - AvcsAgent `image_gen` 支持常用 OpenAI Image API 选项：`size`、`quality`、`output_format`、`output_compression`、`background`、`moderation`。
    - AvcsAgent `image_gen` 支持通过 `mask_asset_id` 对第一张参考图执行 PNG mask 编辑；mask 必须是当前项目内带 alpha 通道的 PNG asset。
    - `gpt-image-2` 不支持 transparent background；正式 variation 仍返回 unsupported 或留给后续计划。
    - `image_gen` tool 由 Phoenix 后端调用 Vercel AI Gateway，生成文件会写入当前项目 `output/` 并入库为 asset、chat item 和 board item。
    - 即使用户要求海报、封面、信息图、带文字视觉稿或需要精确排版，也只能把这些要求整理进 Avcs 后端 `image_gen` tool 提示词；如果工具无法可靠生成精确文字，直接说明限制，不要改用 HTML 排版或浏览器截图。
    - 不要切换到 CLI、SDK、OpenAI API、自定义脚本生成器或其它模型调用路径；远端模型调用只能由 Avcs 后端 tool 执行。
    """
  end

  defp history_messages(project, thread_id, current_turn_id) do
    case Avcs.Turns.list_items(project, thread_id) do
      {:ok, items} ->
        items =
          items
          |> Enum.reject(&(&1["turn_id"] == current_turn_id))
          |> Enum.flat_map(&history_message(project, &1))

        {:ok, items}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp history_message(project, %{"type" => "user_message", "content" => content} = item)
       when is_binary(content) do
    refs =
      item
      |> payload_asset_ids()
      |> Enum.take(@max_history_reference_assets)
      |> reference_assets_from_ids(project)

    [user_message(content, refs, "user_item")]
  end

  defp history_message(_project, %{"type" => "assistant_message", "content" => content})
       when is_binary(content) do
    [%{"role" => "assistant", "content" => content, "avcs_kind" => "assistant_item"}]
  end

  defp history_message(_project, %{"type" => "tool_call"} = item) do
    [
      %{
        "role" => "assistant",
        "content" => "Tool call: #{item["tool_name"] || "tool"}\n#{item["content"] || ""}",
        "avcs_kind" => "tool_call",
        "remote_item_id" => item["remote_item_id"]
      }
    ]
  end

  defp history_message(_project, %{"type" => "tool_result"} = item) do
    [
      %{
        "role" => "system",
        "content" => "Tool result:\n#{tool_result_content(item)}",
        "avcs_kind" => "tool_result"
      }
    ]
  end

  defp history_message(_project, %{"type" => "image_asset"} = item) do
    [
      %{
        "role" => "system",
        "content" => "reference asset: #{item["content"]}",
        "avcs_kind" => "reference_asset"
      }
    ]
  end

  defp history_message(_project, %{"type" => "error"} = item) do
    [
      %{
        "role" => "system",
        "content" => "error: #{item["content"]}",
        "avcs_kind" => "error"
      }
    ]
  end

  defp history_message(_project, _item), do: []

  defp tool_result_content(item) do
    payload = item["payload"] || %{}

    %{
      "type" => "tool_result",
      "tool_name" => payload["tool_name"] || item["tool_name"],
      "status" => item["status"],
      "content" => item["content"],
      "remote_item" => payload["remote_item"]
    }
    |> reject_blank_values()
    |> Jason.encode!()
  end

  defp user_message(text, refs, kind, opts \\ []) do
    text = to_string(text || "")

    content =
      if refs == [] do
        text
      else
        [%{"type" => "text", "text" => text}]
        |> Kernel.++(Enum.map(refs, &image_content_item/1))
      end

    %{
      "role" => "user",
      "content" => content,
      "avcs_kind" => kind,
      "reference_assets" => Enum.map(refs, &reference_asset_summary/1),
      "turn_continuation" => value(opts, :turn_continuation) || kind == "queued_turn_input"
    }
    |> reject_blank_values()
  end

  defp image_content_item(ref) do
    %{
      "type" => "image_url",
      "image_url" => %{
        "url" => ref.data_url,
        "detail" => "auto"
      }
    }
  end

  defp current_reference_assets(project, turn_id, reference_paths) do
    ids =
      project
      |> current_user_item(turn_id)
      |> case do
        nil -> []
        item -> payload_asset_ids(item)
      end

    refs =
      if ids == [] do
        reference_assets_from_paths(project, reference_paths)
      else
        {:ok, reference_assets_from_ids(ids, project)}
      end

    refs
  end

  defp reference_assets_from_paths(project, paths) when is_list(paths) do
    assets =
      case Avcs.Assets.list_assets(project) do
        {:ok, rows} -> rows
        {:error, _reason} -> []
      end

    by_path =
      Map.new(assets, fn asset ->
        {Path.expand(asset["file_path"]), asset}
      end)

    paths
    |> Enum.reduce_while({:ok, []}, fn path, {:ok, acc} ->
      expanded = Path.expand(path)
      asset = Map.get(by_path, expanded)

      case reference_asset(project, asset || %{"file_path" => expanded}) do
        {:ok, ref} -> {:cont, {:ok, [ref | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, refs} -> {:ok, Enum.reverse(refs)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp reference_assets_from_paths(_project, _paths), do: {:ok, []}

  defp reference_assets_from_ids(ids, project) do
    Enum.flat_map(ids, fn id ->
      case Avcs.Assets.get_asset(project, id) do
        {:ok, nil} ->
          []

        {:ok, asset} ->
          case reference_asset(project, asset) do
            {:ok, ref} -> [ref]
            {:error, _reason} -> []
          end

        {:error, _reason} ->
          []
      end
    end)
  end

  defp reference_asset(project, %{"file_path" => file_path} = asset) when is_binary(file_path) do
    with {:ok, relative_path} <- Avcs.Projects.relative_to_project(project, file_path),
         :ok <- ensure_existing_file(file_path),
         :ok <- ensure_reference_image_size(file_path),
         {:ok, bytes} <- File.read(file_path) do
      mime_type = asset["mime_type"] || Avcs.Assets.mime_type(file_path)

      {:ok,
       %{
         id: asset["id"],
         file_name: asset["file_name"] || Path.basename(file_path),
         file_path: file_path,
         relative_path: relative_path,
         mime_type: mime_type,
         width: asset["width"],
         height: asset["height"],
         source: asset["source"],
         size_bytes: byte_size(bytes),
         data_url: "data:#{mime_type};base64,#{Base.encode64(bytes)}"
       }}
    else
      {:error, :outside_project} ->
        {:error, "Referenced image must live inside the current project"}

      {:error, :reference_image_too_large} ->
        {:error,
         "Referenced image is too large for structured model input; use a smaller image or remove it"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp reference_asset(_project, _asset), do: {:error, :reference_asset_not_found}

  defp ensure_existing_file(path) do
    if File.regular?(path), do: :ok, else: {:error, :reference_asset_not_found}
  end

  defp ensure_reference_image_size(path) do
    case File.stat(path) do
      {:ok, %{size: size}} when size <= @max_reference_image_bytes -> :ok
      {:ok, _stat} -> {:error, :reference_image_too_large}
      {:error, reason} -> {:error, reason}
    end
  end

  defp board_context(project) do
    case Avcs.Board.list_items(project) do
      {:ok, items} ->
        {:ok,
         items
         |> Enum.take(@max_board_items)
         |> Enum.map(&board_item_summary/1)}

      {:error, _reason} ->
        {:ok, []}
    end
  end

  defp board_item_summary(item) do
    %{
      "kind" => "board_context",
      "board_item_id" => item["id"],
      "asset_id" => item["asset_id"],
      "file_name" => item["file_name"],
      "relative_path" => item["relative_path"],
      "x" => item["x"],
      "y" => item["y"],
      "display_width" => item["display_width"],
      "display_height" => item["display_height"],
      "z_index" => item["z_index"]
    }
    |> reject_blank_values()
  end

  defp board_context_message([]), do: nil

  defp board_context_message(board_context) do
    "Board context:\n#{Jason.encode!(%{"items" => board_context})}"
  end

  defp model_input_items(system, history, current_user, refs, board_context, opts) do
    [
      %{"kind" => "system", "role" => "system", "content" => system["content"]},
      Enum.map(history, &model_input_item/1),
      model_input_item(current_user),
      Enum.map(refs, &Map.put(reference_asset_summary(&1), "kind", "reference_asset")),
      Enum.map(board_context, &Map.put(&1, "kind", "board_context")),
      data_provider_context(opts) &&
        %{"kind" => "data_provider_context", "content" => data_provider_context(opts)}
    ]
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
  end

  defp model_input_item(message) do
    %{
      "kind" => message["avcs_kind"] || message["role"],
      "role" => message["role"],
      "remote_item_id" => message["remote_item_id"],
      "content" => content_summary(message["content"])
    }
    |> reject_blank_values()
  end

  defp content_summary(content) when is_binary(content), do: String.slice(content, 0, 2_000)

  defp content_summary(content) when is_list(content) do
    Enum.map(content, fn
      %{"type" => "text", "text" => text} ->
        %{"type" => "text", "text" => String.slice(text, 0, 2_000)}

      %{"type" => "image_url"} ->
        %{"type" => "image_url", "omitted" => true}

      other ->
        other
    end)
  end

  defp content_summary(content), do: content

  defp reference_asset_summary(ref) do
    %{
      "asset_id" => ref.id,
      "file_name" => ref.file_name,
      "relative_path" => ref.relative_path,
      "mime_type" => ref.mime_type,
      "width" => ref.width,
      "height" => ref.height,
      "source" => ref.source,
      "size_bytes" => ref.size_bytes
    }
    |> reject_blank_values()
  end

  defp data_provider_context(opts) do
    opts
    |> data_provider()
    |> Avcs.Agent.DataProvider.provider_context()
  end

  defp builtin_skills(opts) do
    ["avcs-imagegen-avcs-agent" | provider_skill_names(opts)]
    |> Avcs.Agent.BuiltinSkillLoader.load()
  end

  defp provider_skill_names(opts) do
    case data_provider(opts) do
      %{"slug" => slug} when is_binary(slug) -> [slug]
      %{slug: slug} when is_binary(slug) -> [slug]
      _provider -> []
    end
  end

  defp skills_section([]), do: nil

  defp skills_section(skills) do
    skills
    |> Enum.map(fn skill ->
      """
      Built-in skill: #{skill["name"]}
      Path: #{skill["path"]}
      #{skill["content"]}
      """
      |> String.trim()
    end)
    |> Enum.join("\n\n")
  end

  defp current_user_item(project, turn_id) when is_binary(turn_id) and turn_id != "" do
    case Avcs.Turns.get_turn(project, turn_id) do
      {:ok, %{"thread_id" => thread_id}} ->
        case Avcs.Turns.list_items(project, thread_id) do
          {:ok, items} ->
            Enum.find(items, &(&1["turn_id"] == turn_id and &1["type"] == "user_message"))

          {:error, _reason} ->
            nil
        end

      {:error, _reason} ->
        nil
    end
  end

  defp current_user_item(_project, _turn_id), do: nil

  defp payload_asset_ids(%{"payload" => payload}) when is_map(payload) do
    case payload["asset_ids"] || payload[:asset_ids] do
      ids when is_list(ids) -> Enum.filter(ids, &is_binary/1)
      _ids -> []
    end
  end

  defp payload_asset_ids(_item), do: []

  defp active_tools(opts) do
    case value(opts, :active_tools) || value(opts, :active_tool_names) do
      names when is_list(names) -> Enum.filter(names, &is_binary/1)
      _names -> Avcs.Agent.Tools.Registry.default_active_tools()
    end
  end

  defp data_provider(opts) when is_map(opts),
    do: Map.get(opts, :data_provider) || Map.get(opts, "data_provider")

  defp data_provider(opts) when is_list(opts), do: Keyword.get(opts, :data_provider)
  defp data_provider(_opts), do: nil

  defp reject_blank_values(map) do
    map
    |> Enum.reject(fn {_key, value} -> blank?(value) end)
    |> Map.new()
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?([]), do: true
  defp blank?(%{}), do: true
  defp blank?(_value), do: false

  defp value(opts, key) when is_map(opts),
    do: Map.get(opts, key) || Map.get(opts, Atom.to_string(key))

  defp value(opts, key) when is_list(opts), do: Keyword.get(opts, key)
  defp value(_opts, _key), do: nil

  defp priv_dir do
    case :code.priv_dir(:avcs) do
      path when is_list(path) -> List.to_string(path)
      {:error, _reason} -> Path.expand("priv", File.cwd!())
    end
  end
end
