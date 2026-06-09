defmodule Avcs.Agent.Tools.ImageGen do
  @moduledoc false

  @behaviour Avcs.Agent.Tool

  @max_count 4
  @max_reference_image_bytes 50 * 1024 * 1024
  @png_signature <<0x89, "PNG", 13, 10, 26, 10>>
  @qualities ~w(low medium high auto)
  @output_formats ~w(png jpeg webp)
  @backgrounds ~w(auto opaque transparent)
  @moderations ~w(auto low)

  @impl true
  def name, do: "image_gen"

  @impl true
  def description do
    "Generate image assets and save them into the current Avcs project output directory. When supported by the configured image model transport, reference_asset_ids are sent as visual references."
  end

  @impl true
  def parameters_schema do
    %{
      "type" => "object",
      "properties" => %{
        "prompt" => %{"type" => "string"},
        "aspect_ratio" => %{"type" => "string"},
        "size" => %{
          "type" => "string",
          "description" =>
            "Optional output size such as auto, 1024x1024, 1024x1536, 1536x1024, or another gpt-image-2 valid WIDTHxHEIGHT value. If omitted, aspect_ratio may be mapped to a size."
        },
        "quality" => %{"type" => "string", "enum" => @qualities},
        "output_format" => %{"type" => "string", "enum" => @output_formats},
        "output_compression" => %{
          "type" => "integer",
          "minimum" => 0,
          "maximum" => 100
        },
        "background" => %{"type" => "string", "enum" => @backgrounds},
        "moderation" => %{"type" => "string", "enum" => @moderations},
        "count" => %{"type" => "integer", "minimum" => 1, "maximum" => @max_count},
        "reference_asset_ids" => %{
          "type" => "array",
          "description" =>
            "Optional project asset ids to use as visual references for the generated image.",
          "items" => %{"type" => "string"}
        },
        "mask_asset_id" => %{
          "type" => "string",
          "description" =>
            "Optional PNG mask asset id for image edits. Requires at least one reference asset; mask must include an alpha channel and match the first reference image size."
        }
      },
      "required" => ["prompt"]
    }
  end

  def schema do
    Avcs.Agent.Tool.schema(__MODULE__)
  end

  @impl true
  def normalize_arguments(arguments, context) do
    with {:ok, args} <- normalize_arguments(arguments) do
      {:ok, maybe_add_provider_reference(args, context)}
    end
  end

  @impl true
  def authorize(args, context) do
    project = value(context, :project)

    cond do
      is_nil(project) ->
        {:error, :project_required}

      not output_dir_inside_project?(project) ->
        {:error, :invalid_output_dir}

      invalid_reference_asset_ids?(args.reference_asset_ids) ->
        {:error, :invalid_reference_asset_ids}

      invalid_optional_asset_id?(args.mask_asset_id) ->
        {:error, :invalid_mask_asset_id}

      args.mask_asset_id && args.reference_asset_ids == [] ->
        {:error, :mask_requires_reference_asset}

      not reference_inputs_supported?(args, context) ->
        {:error, {:unsupported_reference_images, unsupported_reference_images_message(context)}}

      invalid_size?(args.size) ->
        {:error, {:invalid_image_option, "size"}}

      invalid_enum?(args.quality, @qualities) ->
        {:error, {:invalid_image_option, "quality"}}

      invalid_enum?(args.output_format, @output_formats) ->
        {:error, {:invalid_image_option, "output_format"}}

      invalid_output_compression?(args.output_compression) ->
        {:error, {:invalid_image_option, "output_compression"}}

      args.output_compression && args.output_format not in ["jpeg", "webp"] ->
        {:error,
         {:invalid_image_option, "output_compression requires jpeg or webp output_format"}}

      invalid_enum?(args.background, @backgrounds) ->
        {:error, {:invalid_image_option, "background"}}

      args.background == "transparent" and args.output_format == "jpeg" ->
        {:error, {:invalid_image_option, "transparent background requires png or webp"}}

      transparent_background_not_supported?(args.background, value(context, :image_model)) ->
        {:error,
         {:unsupported_image_option, "gpt-image-2 does not support transparent background"}}

      invalid_enum?(args.moderation, @moderations) ->
        {:error, {:invalid_image_option, "moderation"}}

      true ->
        :ok
    end
  end

  @impl true
  def execute(args, context) do
    project = value(context, :project)
    thread_id = value(context, :thread_id)
    turn_id = value(context, :turn_id)
    remote_thread_id = value(context, :remote_thread_id)
    remote_turn_id = value(context, :remote_turn_id)
    tool_call_id = value(context, :tool_call_id)
    image_model = value(context, :image_model)
    progress = value(context, :progress)
    reference_asset_ids = args.reference_asset_ids || []

    emit_progress(progress, "updated", %{
      "stage" => "requesting_image",
      "reference_count" => length(reference_asset_ids)
    })

    with {:ok, reference_images} <- resolve_reference_images(project, reference_asset_ids),
         {:ok, mask_image} <- resolve_mask_image(project, args.mask_asset_id, reference_images),
         {:ok, response} <-
           client().generate_image(args.prompt,
             model: image_model,
             count: args.count,
             reference_images: reference_images,
             mask_image: mask_image,
             size: resolved_size(args),
             quality: args.quality,
             output_format: args.output_format,
             output_compression: args.output_compression,
             background: args.background,
             moderation: args.moderation,
             base_url: value(context, :base_url),
             trace_context: %{
               project: project,
               thread_id: thread_id,
               turn_id: turn_id,
               remote_thread_id: remote_thread_id,
               remote_turn_id: remote_turn_id,
               remote_item_id: tool_call_id,
               model: image_model
             }
           ),
         _ <- emit_progress(progress, "updated", %{"stage" => "saving_images"}),
         {:ok, results} <- persist_images(project, thread_id, turn_id, args, response.images) do
      {:ok,
       %{
         "status" => "completed",
         "model" => response.model,
         "assets" => results,
         "reference_asset_ids" => reference_asset_ids,
         "reference_count" => length(reference_images),
         "mask_asset_id" => args.mask_asset_id,
         "request" => request_summary(args)
       }}
    end
  end

  def generate(project, thread_id, turn_id, arguments, opts \\ []) do
    context = %{
      project: project,
      thread_id: thread_id,
      turn_id: turn_id,
      image_model: value(opts, :image_model),
      base_url: value(opts, :base_url),
      progress: value(opts, :progress)
    }

    with {:ok, args} <- normalize_arguments(arguments, context),
         :ok <- authorize(args, context) do
      execute(args, context)
    end
  end

  defp persist_images(project, thread_id, turn_id, args, images) do
    results =
      images
      |> Enum.with_index(1)
      |> Enum.map(fn {image, index} ->
        persist_image(project, thread_id, turn_id, args, image, index)
      end)

    case Enum.find(results, &match?({:error, _reason}, &1)) do
      nil -> {:ok, Enum.map(results, fn {:ok, result} -> result end)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp persist_image(project, thread_id, turn_id, args, image, index) do
    with {:ok, bytes} <- decode_image(image.base64),
         mime_type <- image_mime(bytes, image.mime_type),
         extension <- extension_for_mime(mime_type),
         {:ok, path} <- write_output_image(project, bytes, extension, index),
         {:ok, asset} <-
           Avcs.Assets.upsert_asset(project, path,
             source: "generated",
             thread_id: thread_id,
             turn_id: turn_id,
             prompt: args.prompt
           ),
         {:ok, relative_path} <- Avcs.Projects.relative_to_project(project, path),
         {:ok, item} <- append_image_item(project, thread_id, turn_id, asset, path, args) do
      Avcs.Events.broadcast("asset:created", %{asset: asset})
      Avcs.Events.broadcast("item:created", %{thread_id: thread_id, turn_id: turn_id, item: item})
      broadcast_board_item(project, asset)

      {:ok,
       %{
         "asset_id" => asset["id"],
         "relative_path" => relative_path,
         "width" => asset["width"],
         "height" => asset["height"],
         "hash" => asset["hash"],
         "mime_type" => asset["mime_type"] || mime_type,
         "status" => "saved"
       }}
    end
  end

  defp broadcast_board_item(project, asset) do
    case Avcs.Assets.output_board_item(project, asset["id"]) do
      {:ok, board_item} ->
        Avcs.Events.broadcast("board:item:created", %{item: board_item})

      {:error, _reason} ->
        :ok
    end
  end

  defp append_image_item(project, thread_id, turn_id, asset, path, args) do
    Avcs.Turns.append_item(project,
      turn_id: turn_id,
      thread_id: thread_id,
      type: "image_asset",
      role: "assistant",
      content: asset["file_name"],
      payload: %{
        asset_id: asset["id"],
        source_path: path,
        prompt: args.prompt,
        aspect_ratio: args.aspect_ratio,
        reference_asset_ids: args.reference_asset_ids,
        mask_asset_id: args.mask_asset_id,
        size: resolved_size(args),
        quality: args.quality,
        output_format: args.output_format,
        output_compression: args.output_compression,
        background: args.background,
        moderation: args.moderation
      }
    )
  end

  defp write_output_image(project, bytes, extension, index) do
    output_dir = Avcs.Projects.output_dir(project)
    File.mkdir_p!(output_dir)

    base =
      "avcs-agent-" <>
        (DateTime.utc_now()
         |> Calendar.strftime("%Y%m%d-%H%M%S")) <>
        "-" <> Integer.to_string(System.unique_integer([:positive]))

    path =
      Path.join(
        output_dir,
        "#{base}-#{String.pad_leading(to_string(index), 2, "0")}.#{extension}"
      )

    case File.write(path, bytes) do
      :ok -> {:ok, path}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_arguments(arguments) when is_binary(arguments) do
    case Jason.decode(arguments) do
      {:ok, decoded} -> normalize_arguments(decoded)
      {:error, reason} -> {:error, "Invalid image_gen arguments: #{Exception.message(reason)}"}
    end
  end

  defp normalize_arguments(arguments) when is_map(arguments) do
    prompt = arguments["prompt"] || arguments[:prompt]

    if is_binary(prompt) and String.trim(prompt) != "" do
      {:ok,
       %{
         prompt: String.trim(prompt),
         aspect_ratio:
           clean_optional_string(arguments["aspect_ratio"] || arguments[:aspect_ratio]),
         size: clean_optional_string(arguments["size"] || arguments[:size]),
         quality: clean_optional_string(arguments["quality"] || arguments[:quality]),
         output_format:
           clean_optional_string(arguments["output_format"] || arguments[:output_format]),
         output_compression:
           normalize_optional_integer(
             arguments["output_compression"] || arguments[:output_compression]
           ),
         background: clean_optional_string(arguments["background"] || arguments[:background]),
         moderation: clean_optional_string(arguments["moderation"] || arguments[:moderation]),
         count: normalize_count(arguments["count"] || arguments[:count]),
         reference_asset_ids:
           normalize_reference_asset_ids(
             arguments["reference_asset_ids"] || arguments[:reference_asset_ids]
           ),
         mask_asset_id:
           clean_optional_string(arguments["mask_asset_id"] || arguments[:mask_asset_id])
       }}
    else
      {:error, :image_gen_prompt_required}
    end
  end

  defp normalize_arguments(_arguments), do: {:error, :invalid_image_gen_arguments}

  defp normalize_count(count) when is_integer(count), do: count |> max(1) |> min(@max_count)

  defp normalize_count(count) when is_binary(count) do
    case Integer.parse(String.trim(count)) do
      {integer, ""} -> normalize_count(integer)
      _other -> 1
    end
  end

  defp normalize_count(_count), do: 1

  defp normalize_optional_integer(nil), do: nil
  defp normalize_optional_integer(value) when is_integer(value), do: value

  defp normalize_optional_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {integer, ""} -> integer
      _other -> value
    end
  end

  defp normalize_optional_integer(value), do: value

  defp normalize_reference_asset_ids(nil), do: []

  defp normalize_reference_asset_ids(id) when is_binary(id) do
    [String.trim(id)]
  end

  defp normalize_reference_asset_ids(ids) when is_list(ids) do
    Enum.map(ids, fn
      id when is_binary(id) -> String.trim(id)
      id -> id
    end)
  end

  defp normalize_reference_asset_ids(ids), do: ids

  defp maybe_add_provider_reference(args, context) do
    provider_asset_id = provider_reference_asset_id(context)

    cond do
      reference_transport_supports_images?(context) ->
        maybe_add_supported_provider_reference(args, provider_asset_id)

      args.mask_asset_id ->
        args

      provider_asset_id && args.reference_asset_ids == [provider_asset_id] ->
        %{args | reference_asset_ids: []}

      true ->
        args
    end
  end

  defp maybe_add_supported_provider_reference(%{reference_asset_ids: []} = args, asset_id)
       when is_binary(asset_id) do
    %{args | reference_asset_ids: [asset_id]}
  end

  defp maybe_add_supported_provider_reference(args, _asset_id), do: args

  defp provider_reference_asset_id(context) do
    context =
      value(context, :data_provider_context) ||
        value(context, :provider_context) ||
        %{}

    result =
      value(context, :result) ||
        value(context, :summary) ||
        context

    media_type = value(result, :media_type)
    asset_id = clean_optional_string(value(result, :asset_id))

    cond do
      is_nil(asset_id) ->
        nil

      provider_result_image?(result, media_type) ->
        asset_id

      true ->
        nil
    end
  end

  defp provider_result_image?(result, media_type) do
    media_type == "image" or
      (is_nil(media_type) and image_like_path?(value(result, :image_path)))
  end

  defp image_like_path?(path) when is_binary(path) and path != "" do
    Avcs.Assets.supported_image?(path)
  end

  defp image_like_path?(_path), do: false

  defp request_summary(args) do
    %{
      "size" => resolved_size(args),
      "aspect_ratio" => args.aspect_ratio,
      "quality" => args.quality,
      "output_format" => args.output_format,
      "output_compression" => args.output_compression,
      "background" => args.background,
      "moderation" => args.moderation
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) or value == "" end)
    |> Map.new()
  end

  defp resolved_size(%{size: size}) when is_binary(size) and size != "", do: size
  defp resolved_size(%{aspect_ratio: ratio}), do: size_for_aspect_ratio(ratio)
  defp resolved_size(_args), do: nil

  defp size_for_aspect_ratio(nil), do: nil
  defp size_for_aspect_ratio("1:1"), do: "1024x1024"
  defp size_for_aspect_ratio("2:3"), do: "1024x1536"
  defp size_for_aspect_ratio("3:2"), do: "1536x1024"
  defp size_for_aspect_ratio("3:4"), do: "1152x1536"
  defp size_for_aspect_ratio("4:3"), do: "1536x1152"
  defp size_for_aspect_ratio("4:5"), do: "1280x1600"
  defp size_for_aspect_ratio("5:4"), do: "1600x1280"
  defp size_for_aspect_ratio("9:16"), do: "1024x1824"
  defp size_for_aspect_ratio("16:9"), do: "1824x1024"
  defp size_for_aspect_ratio(_ratio), do: nil

  defp resolve_reference_images(_project, []), do: {:ok, []}

  defp resolve_reference_images(project, ids) do
    ids
    |> Enum.reduce_while({:ok, []}, fn id, {:ok, images} ->
      case resolve_reference_image(project, id) do
        {:ok, image} -> {:cont, {:ok, [image | images]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, images} -> {:ok, Enum.reverse(images)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp resolve_reference_image(project, id) do
    case Avcs.Assets.get_asset(project, id) do
      {:ok, %{"file_path" => path} = asset} when is_binary(path) ->
        reference_image_from_asset(project, asset, path)

      {:ok, nil} ->
        {:error, {:reference_asset_not_found, id}}

      {:ok, _asset} ->
        {:error, {:reference_asset_not_found, id}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp reference_image_from_asset(project, asset, path) do
    with {:ok, relative_path} <- Avcs.Projects.relative_to_project(project, path),
         :ok <- ensure_reference_image_file(path),
         :ok <- ensure_reference_image_size(path) do
      {:ok,
       %{
         asset_id: asset["id"],
         path: path,
         relative_path: relative_path,
         file_name: asset["file_name"] || Path.basename(path),
         mime_type: asset["mime_type"] || Avcs.Assets.mime_type(path)
       }}
    else
      {:error, :outside_project} ->
        {:error, :reference_asset_outside_project}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp resolve_mask_image(_project, nil, _reference_images), do: {:ok, nil}

  defp resolve_mask_image(project, id, reference_images) do
    with {:ok, mask} <- resolve_reference_image(project, id),
         :ok <- ensure_mask_png(mask),
         :ok <- ensure_mask_dimensions(mask, List.first(reference_images)) do
      {:ok, mask}
    end
  end

  defp ensure_mask_png(%{path: path}) do
    case File.read(path) do
      {:ok, @png_signature <> _rest = bytes} ->
        if png_has_alpha_channel?(bytes), do: :ok, else: {:error, :mask_must_have_alpha_channel}

      {:ok, _bytes} ->
        {:error, :mask_must_be_png}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp png_has_alpha_channel?(@png_signature <> rest) do
    case png_ihdr_color_type(rest) do
      color_type when color_type in [4, 6] -> true
      _color_type -> png_has_trns_chunk?(rest)
    end
  end

  defp png_has_alpha_channel?(_bytes), do: false

  defp png_ihdr_color_type(
         <<0, 0, 0, 13, "IHDR", _width::32, _height::32, _bit_depth, color_type, _compression,
           _filter, _interlace, _crc::32, _rest::binary>>
       ) do
    color_type
  end

  defp png_ihdr_color_type(_bytes), do: nil

  defp png_has_trns_chunk?(
         <<length::32, type::binary-size(4), _data::binary-size(length), _crc::32, rest::binary>>
       ) do
    type == "tRNS" or (type != "IEND" and png_has_trns_chunk?(rest))
  end

  defp png_has_trns_chunk?(_bytes), do: false

  defp ensure_mask_dimensions(_mask, nil), do: :ok

  defp ensure_mask_dimensions(mask, reference) do
    case {Avcs.Assets.image_dimensions(mask.path), Avcs.Assets.image_dimensions(reference.path)} do
      {{mask_width, mask_height}, {reference_width, reference_height}}
      when is_integer(mask_width) and is_integer(mask_height) and
             is_integer(reference_width) and is_integer(reference_height) and
             mask_width > 0 and mask_height > 0 and reference_width > 0 and reference_height > 0 ->
        if {mask_width, mask_height} == {reference_width, reference_height} do
          :ok
        else
          {:error, :mask_dimensions_mismatch}
        end

      _dimensions ->
        :ok
    end
  end

  defp ensure_reference_image_file(path) do
    cond do
      not File.regular?(path) ->
        {:error, :reference_asset_not_found}

      not Avcs.Assets.supported_image?(path) ->
        {:error, :unsupported_reference_image_format}

      true ->
        :ok
    end
  end

  defp ensure_reference_image_size(path) do
    case File.stat(path) do
      {:ok, %{size: size}} when size <= @max_reference_image_bytes -> :ok
      {:ok, _stat} -> {:error, :reference_image_too_large}
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_image(base64) do
    base64
    |> String.replace(~r/\s+/, "")
    |> Base.decode64()
    |> case do
      {:ok, bytes} -> {:ok, bytes}
      :error -> {:error, :invalid_image_base64}
    end
  end

  defp image_mime(<<0x89, "PNG", _rest::binary>>, _fallback), do: "image/png"
  defp image_mime(<<0xFF, 0xD8, _rest::binary>>, _fallback), do: "image/jpeg"

  defp image_mime(<<"RIFF", _::binary-size(4), "WEBP", _rest::binary>>, _fallback),
    do: "image/webp"

  defp image_mime(_bytes, fallback) when is_binary(fallback) and fallback != "", do: fallback
  defp image_mime(_bytes, _fallback), do: "image/png"

  defp extension_for_mime("image/jpeg"), do: "jpg"
  defp extension_for_mime("image/webp"), do: "webp"
  defp extension_for_mime(_mime), do: "png"

  defp clean_optional_string(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> nil
      clean -> clean
    end
  end

  defp clean_optional_string(_value), do: nil

  defp output_dir_inside_project?(project) do
    with {:ok, _relative} <-
           Avcs.Projects.relative_to_project(project, Avcs.Projects.output_dir(project)) do
      true
    else
      _error -> false
    end
  end

  defp invalid_reference_asset_ids?(ids) when is_list(ids),
    do: Enum.any?(ids, &(not is_binary(&1) or &1 == ""))

  defp invalid_reference_asset_ids?(_ids), do: true

  defp invalid_optional_asset_id?(nil), do: false
  defp invalid_optional_asset_id?(id), do: not is_binary(id) or id == ""

  defp invalid_size?(nil), do: false
  defp invalid_size?("auto"), do: false

  defp invalid_size?(size) when is_binary(size) do
    case Regex.run(~r/^(\d+)x(\d+)$/, size) do
      [_, width, height] ->
        width = String.to_integer(width)
        height = String.to_integer(height)

        width <= 0 or height <= 0 or rem(width, 16) != 0 or rem(height, 16) != 0 or
          max(width, height) > 3840 or max(width, height) / min(width, height) > 3 or
          width * height < 655_360 or width * height > 8_294_400

      _no_match ->
        true
    end
  end

  defp invalid_size?(_size), do: true

  defp invalid_enum?(nil, _allowed), do: false
  defp invalid_enum?(value, allowed), do: value not in allowed

  defp invalid_output_compression?(nil), do: false

  defp invalid_output_compression?(value) when is_integer(value),
    do: value < 0 or value > 100

  defp invalid_output_compression?(_value), do: true

  defp reference_inputs_supported?(args, context) do
    (args.reference_asset_ids == [] and is_nil(args.mask_asset_id)) or
      reference_transport_supports_images?(context)
  end

  defp reference_transport_supports_images?(context) do
    Avcs.Agent.ImageModelCapabilities.supports_reference_images?(
      avcs_agent_base_url(context),
      value(context, :image_model)
    )
  end

  defp unsupported_reference_images_message(context) do
    model = value(context, :image_model) || "the configured image model"

    "Vercel AI Gateway does not support reference images or mask edits for image-only model #{model}. Use text-only image generation or choose a Gemini image model for reference-based generation."
  end

  defp avcs_agent_base_url(context) do
    value(context, :base_url) ||
      value(context, :image_base_url) ||
      runtime_base_url()
  end

  defp runtime_base_url do
    Avcs.SiteSettings.avcs_agent_runtime_settings().base_url
  rescue
    _exception -> nil
  end

  defp transparent_background_not_supported?("transparent", model) when is_binary(model) do
    String.contains?(model, "gpt-image-2")
  end

  defp transparent_background_not_supported?(_background, _model), do: false

  defp emit_progress(fun, status, payload) when is_function(fun, 2), do: fun.(status, payload)
  defp emit_progress(_fun, _status, _payload), do: :ok

  defp client do
    Application.get_env(:avcs, :avcs_agent_client, Avcs.Agent.AvcsAgentClient)
  end

  defp value(opts, key) when is_list(opts), do: Keyword.get(opts, key)

  defp value(opts, key) when is_map(opts),
    do: Map.get(opts, key) || Map.get(opts, Atom.to_string(key))

  defp value(_opts, _key), do: nil
end
