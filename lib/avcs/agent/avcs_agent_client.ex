defmodule Avcs.Agent.AvcsAgentClient do
  @moduledoc false

  alias Avcs.Agent.VercelApiTrace

  @default_request_timeout_ms 300_000
  @default_connect_timeout_ms 30_000
  @default_stream_retry_attempts 3
  @default_stream_retry_backoff_ms [500, 1_500]
  @retry_sleep_interval_ms 50
  @retryable_stream_statuses [408, 429, 500, 502, 503, 504]

  def configured? do
    settings = Avcs.SiteSettings.avcs_agent_runtime_settings()
    present?(settings.api_key) and present?(settings.base_url)
  end

  def test_connection(opts \\ []) do
    settings = runtime_settings(opts)

    with :ok <- require_api_key(settings),
         {:ok, _status, body} <- request(:get, endpoint(settings, "/models"), nil, settings) do
      case Jason.decode(body) do
        {:ok, %{"data" => models}} when is_list(models) -> {:ok, %{models_count: length(models)}}
        {:ok, _json} -> {:ok, %{models_count: nil}}
        {:error, reason} -> {:error, "AI Gateway returned invalid JSON: #{inspect(reason)}"}
      end
    end
  end

  def chat_completion(messages, tools, opts \\ []) do
    settings = runtime_settings(opts)
    model = value(opts, :model) || settings.text_model

    payload =
      %{
        model: model,
        messages: messages,
        tools: tools,
        tool_choice: "auto",
        stream: false
      }
      |> compact()

    with :ok <- require_api_key(settings),
         {:ok, _status, body} <-
           request(
             :post,
             endpoint(settings, "/chat/completions"),
             payload,
             settings,
             trace_meta(opts, payload, "http_json")
           ),
         {:ok, json} <- Jason.decode(body) do
      {:ok, parse_completion(json)}
    else
      {:error, %Jason.DecodeError{} = reason} ->
        {:error, "AI Gateway returned invalid JSON: #{Exception.message(reason)}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def chat_completion_stream(messages, tools, opts \\ [], on_event, interrupted?) do
    settings = runtime_settings(opts)
    model = value(opts, :model) || settings.text_model

    payload =
      %{
        model: model,
        messages: messages,
        tools: tools,
        tool_choice: "auto",
        stream: true
      }
      |> compact()

    with :ok <- require_api_key(settings) do
      case stream_request(
             endpoint(settings, "/chat/completions"),
             payload,
             settings,
             on_event,
             interrupted?,
             trace_meta(opts, payload, "sse")
           ) do
        {:ok, result} -> {:ok, Map.put_new(result, :remote_model, model)}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  def generate_image(prompt, opts \\ []) do
    settings = runtime_settings(opts)
    model = value(opts, :model) || settings.image_model
    count = value(opts, :count) || 1
    reference_images = List.wrap(value(opts, :reference_images) || [])
    mask_image = value(opts, :mask_image)

    with :ok <- require_api_key(settings),
         {:ok, _status, body} <-
           image_request(settings, model, prompt, count, reference_images, mask_image, opts),
         {:ok, json} <- Jason.decode(body) do
      images = images_from_response(json)

      if images == [] do
        {:error, :no_image_data}
      else
        {:ok, %{model: model, images: images, raw_id: json["id"]}}
      end
    else
      {:error, %Jason.DecodeError{} = reason} ->
        {:error, "AI Gateway returned invalid JSON: #{Exception.message(reason)}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp image_request(settings, model, prompt, count, [], nil, opts) do
    cond do
      unsupported_explicit_chat_image_model?(settings, model, opts) ->
        {:error, unsupported_chat_image_model_message(model)}

      chat_completions_image_request?(settings, model, [], nil, opts) ->
        chat_image_request(settings, model, prompt, count, [], nil, opts)

      true ->
        payload =
          %{
            model: model,
            prompt: prompt,
            n: count,
            response_format: image_response_format(model)
          }
          |> Map.merge(image_option_fields(opts))
          |> compact()

        request(
          :post,
          endpoint(settings, "/images/generations"),
          payload,
          settings,
          trace_meta(opts, payload, "http_json", summary_opts: image_summary_opts([], nil, opts))
        )
    end
  end

  defp image_request(settings, model, prompt, count, reference_images, mask_image, opts) do
    cond do
      unsupported_explicit_chat_image_model?(settings, model, opts) ->
        {:error, unsupported_chat_image_model_message(model)}

      chat_completions_image_request?(settings, model, reference_images, mask_image, opts) ->
        chat_image_request(settings, model, prompt, count, reference_images, mask_image, opts)

      not Avcs.Agent.ImageModelCapabilities.supports_reference_images?(settings.base_url, model) ->
        {:error, unsupported_reference_images_message(model)}

      true ->
        image_edit_request(settings, model, prompt, count, reference_images, mask_image, opts)
    end
  end

  defp image_edit_request(settings, model, prompt, count, reference_images, mask_image, opts) do
    fields =
      %{
        "model" => model,
        "prompt" => prompt,
        "n" => count
      }
      |> Map.merge(image_option_fields(opts))
      |> compact()

    files =
      Enum.map(reference_images, fn image ->
        %{
          field_name: "image[]",
          path: value(image, :path),
          file_name: value(image, :file_name) || Path.basename(value(image, :path) || "image"),
          mime_type: value(image, :mime_type) || "application/octet-stream"
        }
      end)
      |> Kernel.++(mask_file(mask_image))

    request_multipart(
      endpoint(settings, "/images/edits"),
      fields,
      files,
      settings,
      trace_meta(opts, nil, "http_multipart",
        request_summary:
          VercelApiTrace.multipart_request_summary(
            fields,
            files,
            image_summary_opts(reference_images, mask_image, opts)
          )
      )
    )
  end

  defp chat_image_request(settings, model, prompt, count, reference_images, mask_image, opts) do
    with {:ok, content} <- chat_image_content(prompt, reference_images, mask_image, opts) do
      payload =
        %{
          model: model,
          messages: [
            %{
              role: "user",
              content: content
            }
          ],
          modalities: ["image"],
          n: count,
          stream: false
        }
        |> compact()

      request(
        :post,
        endpoint(settings, "/chat/completions"),
        payload,
        settings,
        trace_meta(opts, payload, "http_json",
          summary_opts: image_summary_opts(reference_images, mask_image, opts)
        )
      )
    end
  end

  defp chat_completions_image_request?(settings, model, reference_images, mask_image, opts) do
    case value(opts, :image_transport) do
      :chat_completions ->
        true

      "chat_completions" ->
        true

      :image_api ->
        false

      "image_api" ->
        false

      _transport ->
        Avcs.Agent.ImageModelCapabilities.vercel_ai_gateway?(settings.base_url) and
          image_input?(reference_images, mask_image) and
          not Avcs.Agent.ImageModelCapabilities.vercel_image_api_only_model?(
            settings.base_url,
            model
          )
    end
  end

  defp unsupported_explicit_chat_image_model?(settings, model, opts) do
    value(opts, :image_transport) in [:chat_completions, "chat_completions"] and
      Avcs.Agent.ImageModelCapabilities.vercel_image_api_only_model?(settings.base_url, model)
  end

  defp image_input?(reference_images, mask_image) do
    reference_images != [] or not is_nil(mask_image)
  end

  defp unsupported_chat_image_model_message(model) do
    "Vercel AI Gateway treats #{model || "the configured image model"} as an Images API model, not a Chat Completions language model. Use /images/generations for text-only generation or choose a multimodal chat image model for reference images."
  end

  defp unsupported_reference_images_message(model) do
    "Vercel AI Gateway does not support reference images for image-only model #{model || "the configured image model"} through the Chat Completions path. Use text-only generation with /images/generations or choose a multimodal chat image model for reference images."
  end

  defp chat_image_content(prompt, reference_images, mask_image, opts) do
    images = reference_images ++ List.wrap(mask_image || [])

    images
    |> Enum.reduce_while({:ok, [chat_text_part(prompt, mask_image, opts)]}, fn image,
                                                                               {:ok, parts} ->
      case chat_image_part(image) do
        {:ok, part} -> {:cont, {:ok, [parts, part]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, parts} -> {:ok, List.flatten(parts)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp chat_text_part(prompt, nil, opts) do
    %{"type" => "text", "text" => image_prompt_with_options(prompt, opts)}
  end

  defp chat_text_part(prompt, _mask_image, opts) do
    %{
      "type" => "text",
      "text" =>
        image_prompt_with_options(prompt, opts) <>
          "\n\nThe final input image is an alpha-channel PNG mask. Transparent areas indicate the region to edit; opaque areas should remain as close to the base image as possible."
    }
  end

  defp chat_image_part(image) do
    path = value(image, :path)
    mime_type = value(image, :mime_type) || "application/octet-stream"

    with true <- is_binary(path) and path != "",
         {:ok, bytes} <- File.read(path) do
      {:ok,
       %{
         "type" => "image_url",
         "image_url" => %{"url" => "data:#{mime_type};base64,#{Base.encode64(bytes)}"}
       }}
    else
      false -> {:error, :invalid_reference_image_path}
      {:error, reason} -> {:error, "Cannot read reference image: #{inspect(reason)}"}
    end
  end

  defp image_prompt_with_options(prompt, opts) do
    options =
      opts
      |> image_option_fields()
      |> Enum.reject(fn {_key, value} -> is_nil(value) or value == "" end)
      |> Enum.map(fn {key, value} -> "#{key}: #{value}" end)

    case options do
      [] -> prompt
      _options -> prompt <> "\n\nImage request options: " <> Enum.join(options, "; ") <> "."
    end
  end

  defp image_option_fields(opts) do
    %{
      "size" => value(opts, :size),
      "quality" => value(opts, :quality),
      "output_format" => value(opts, :output_format),
      "output_compression" => value(opts, :output_compression),
      "background" => value(opts, :background),
      "moderation" => value(opts, :moderation)
    }
  end

  defp image_response_format(model) when is_binary(model) do
    if String.contains?(model, "gpt-image"), do: nil, else: "b64_json"
  end

  defp image_response_format(_model), do: nil

  defp mask_file(nil), do: []

  defp mask_file(mask_image) do
    [
      %{
        field_name: "mask",
        path: value(mask_image, :path),
        file_name:
          value(mask_image, :file_name) || Path.basename(value(mask_image, :path) || "mask"),
        mime_type: value(mask_image, :mime_type) || "image/png"
      }
    ]
  end

  defp runtime_settings(opts) do
    settings = Avcs.SiteSettings.avcs_agent_runtime_settings()

    %{
      settings
      | base_url: value(opts, :base_url) || settings.base_url,
        api_key: value(opts, :api_key) || settings.api_key,
        text_model: value(opts, :text_model) || settings.text_model,
        image_model: value(opts, :image_model) || settings.image_model
    }
  end

  defp request(method, url, payload, settings, trace_meta \\ %{}) do
    ensure_http_started()

    trace_context = VercelApiTrace.context_from_opts(trace_meta)
    trace_meta = trace_request_meta(method, url, payload, trace_meta, 1, 1)
    started_at_ms = System.monotonic_time(:millisecond)
    VercelApiTrace.append_request_sent(trace_context, trace_meta)

    headers = [
      {~c"authorization", to_charlist("Bearer " <> settings.api_key)},
      {~c"content-type", ~c"application/json"}
    ]

    http_opts = http_options()
    opts = [body_format: :binary]

    request =
      case method do
        :get -> {to_charlist(url), headers}
        :post -> {to_charlist(url), headers, ~c"application/json", Jason.encode!(payload)}
      end

    case :httpc.request(method, request, http_opts, opts) do
      {:ok, {{_version, status, _reason}, _headers, body}} when status in 200..299 ->
        VercelApiTrace.append_response_received(
          trace_context,
          "ok",
          trace_meta
          |> Map.put(
            :response_summary,
            VercelApiTrace.response_summary(body,
              http_status: status,
              duration_ms: VercelApiTrace.duration_ms(started_at_ms)
            )
          )
        )

        {:ok, status, body}

      {:ok, {{_version, status, reason}, _headers, body}} ->
        VercelApiTrace.append_response_received(
          trace_context,
          "error",
          trace_meta
          |> Map.put(
            :response_summary,
            VercelApiTrace.response_summary(body,
              http_status: status,
              duration_ms: VercelApiTrace.duration_ms(started_at_ms),
              reason: to_string(reason)
            )
          )
        )

        {:error, gateway_error(status, reason, body, payload)}

      {:error, reason} ->
        trace_request_failure(trace_context, trace_meta, reason, started_at_ms, false, false)
        {:error, "AI Gateway request failed: #{inspect(reason)}"}
    end
  end

  defp request_multipart(url, fields, files, settings, trace_meta) do
    ensure_http_started()

    boundary = multipart_boundary()

    with {:ok, body} <- multipart_body(boundary, fields, files) do
      trace_context = VercelApiTrace.context_from_opts(trace_meta)
      trace_meta = trace_request_meta(:post, url, nil, trace_meta, 1, 1)
      started_at_ms = System.monotonic_time(:millisecond)
      VercelApiTrace.append_request_sent(trace_context, trace_meta)

      headers = [
        {~c"authorization", to_charlist("Bearer " <> settings.api_key)}
      ]

      content_type = "multipart/form-data; boundary=#{boundary}"
      http_opts = http_options()
      opts = [body_format: :binary]
      request = {to_charlist(url), headers, to_charlist(content_type), body}
      error_payload = %{"multipart_images" => length(files)}

      case :httpc.request(:post, request, http_opts, opts) do
        {:ok, {{_version, status, _reason}, _headers, body}} when status in 200..299 ->
          VercelApiTrace.append_response_received(
            trace_context,
            "ok",
            trace_meta
            |> Map.put(
              :response_summary,
              VercelApiTrace.response_summary(body,
                http_status: status,
                duration_ms: VercelApiTrace.duration_ms(started_at_ms)
              )
            )
          )

          {:ok, status, body}

        {:ok, {{_version, status, reason}, _headers, body}} ->
          VercelApiTrace.append_response_received(
            trace_context,
            "error",
            trace_meta
            |> Map.put(
              :response_summary,
              VercelApiTrace.response_summary(body,
                http_status: status,
                duration_ms: VercelApiTrace.duration_ms(started_at_ms),
                reason: to_string(reason)
              )
            )
          )

          {:error, gateway_error(status, reason, body, error_payload)}

        {:error, reason} ->
          trace_request_failure(trace_context, trace_meta, reason, started_at_ms, false, false)
          {:error, "AI Gateway request failed: #{inspect(reason)}"}
      end
    end
  end

  defp multipart_boundary do
    "avcs-" <> (:crypto.strong_rand_bytes(18) |> Base.encode16(case: :lower))
  end

  defp multipart_body(boundary, fields, files) do
    fields_part =
      fields
      |> Enum.map(fn {name, value} -> multipart_field_part(boundary, name, value) end)

    files
    |> Enum.reduce_while({:ok, fields_part}, fn file, {:ok, parts} ->
      case multipart_file_part(boundary, file) do
        {:ok, part} -> {:cont, {:ok, [parts, part]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, parts} -> {:ok, IO.iodata_to_binary([parts, "--", boundary, "--\r\n"])}
      {:error, reason} -> {:error, reason}
    end
  end

  defp multipart_field_part(boundary, name, value) do
    [
      "--",
      boundary,
      "\r\n",
      "Content-Disposition: form-data; name=\"",
      multipart_header_value(name),
      "\"\r\n\r\n",
      to_string(value),
      "\r\n"
    ]
  end

  defp multipart_file_part(boundary, file) do
    path = value(file, :path)

    with true <- is_binary(path) and path != "",
         {:ok, bytes} <- File.read(path) do
      {:ok,
       [
         "--",
         boundary,
         "\r\n",
         "Content-Disposition: form-data; name=\"",
         multipart_header_value(value(file, :field_name) || "image[]"),
         "\"; filename=\"",
         multipart_header_value(value(file, :file_name) || Path.basename(path)),
         "\"\r\n",
         "Content-Type: ",
         multipart_header_value(value(file, :mime_type) || "application/octet-stream"),
         "\r\n\r\n",
         bytes,
         "\r\n"
       ]}
    else
      false -> {:error, :invalid_multipart_file_path}
      {:error, reason} -> {:error, "Cannot read reference image: #{inspect(reason)}"}
    end
  end

  defp multipart_header_value(value) do
    value
    |> to_string()
    |> String.replace(~r/[\r\n]/, " ")
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
  end

  defp stream_request(url, payload, settings, on_event, interrupted?, trace_meta) do
    retry_stream_request(
      url,
      payload,
      settings,
      on_event,
      interrupted?,
      trace_meta,
      1,
      stream_retry_attempts()
    )
  end

  defp retry_stream_request(
         url,
         payload,
         settings,
         on_event,
         interrupted?,
         trace_meta,
         attempt,
         max_attempts
       ) do
    case do_stream_request(
           url,
           payload,
           settings,
           on_event,
           interrupted?,
           trace_meta,
           attempt,
           max_attempts
         ) do
      {:error, {:retryable_stream_failure, _reason}} when attempt < max_attempts ->
        case wait_for_stream_retry(stream_retry_backoff_ms(attempt), interrupted?) do
          :ok ->
            retry_stream_request(
              url,
              payload,
              settings,
              on_event,
              interrupted?,
              trace_meta,
              attempt + 1,
              max_attempts
            )

          {:error, :interrupted} ->
            {:error, :interrupted}
        end

      {:error, {:retryable_stream_failure, reason}} ->
        {:error, reason}

      {:error, {:stream_failure, reason}} ->
        {:error, reason}

      result ->
        result
    end
  end

  defp do_stream_request(
         url,
         payload,
         settings,
         on_event,
         interrupted?,
         trace_meta,
         attempt,
         max_attempts
       ) do
    ensure_http_started()

    trace_context = VercelApiTrace.context_from_opts(trace_meta)
    trace_meta = trace_request_meta(:post, url, payload, trace_meta, attempt, max_attempts)
    started_at_ms = System.monotonic_time(:millisecond)
    VercelApiTrace.append_request_sent(trace_context, trace_meta)

    headers = [
      {~c"authorization", to_charlist("Bearer " <> settings.api_key)},
      {~c"content-type", ~c"application/json"},
      {~c"accept", ~c"text/event-stream"}
    ]

    request = {to_charlist(url), headers, ~c"application/json", Jason.encode!(payload)}
    http_opts = http_options()
    opts = [sync: false, stream: :self, body_format: :binary]

    case :httpc.request(:post, request, http_opts, opts) do
      {:ok, request_id} ->
        collect_stream(
          request_id,
          "",
          empty_stream_acc(),
          payload,
          on_event,
          interrupted?,
          trace_context,
          trace_meta,
          started_at_ms
        )

      {:error, reason} ->
        trace_request_failure(
          trace_context,
          trace_meta,
          reason,
          started_at_ms,
          false,
          retryable_stream_transport_error?(reason)
        )

        stream_transport_error(reason, false)
    end
  end

  defp collect_stream(
         request_id,
         buffer,
         acc,
         payload,
         on_event,
         interrupted?,
         trace_context,
         trace_meta,
         started_at_ms
       ) do
    if interrupted?.() do
      :httpc.cancel_request(request_id)

      VercelApiTrace.append_request_interrupted(
        trace_context,
        trace_meta
        |> Map.put(
          :error_summary,
          VercelApiTrace.transport_error_summary(:interrupted,
            duration_ms: VercelApiTrace.duration_ms(started_at_ms),
            committed: acc.committed?
          )
        )
      )

      {:error, :interrupted}
    else
      receive do
        {:http, {^request_id, :stream_start, _headers}} ->
          collect_stream(
            request_id,
            buffer,
            acc,
            payload,
            on_event,
            interrupted?,
            trace_context,
            trace_meta,
            started_at_ms
          )

        {:http, {^request_id, :stream, chunk}} ->
          {buffer, acc} = consume_sse(buffer <> to_string(chunk), acc, on_event)

          collect_stream(
            request_id,
            buffer,
            acc,
            payload,
            on_event,
            interrupted?,
            trace_context,
            trace_meta,
            started_at_ms
          )

        {:http, {^request_id, :stream_end, _headers}} ->
          {_buffer, acc} = consume_sse(buffer <> "\n\n", acc, on_event)

          VercelApiTrace.append_response_received(
            trace_context,
            "ok",
            trace_meta
            |> Map.put(
              :response_summary,
              VercelApiTrace.stream_response_summary(acc,
                http_status: 200,
                duration_ms: VercelApiTrace.duration_ms(started_at_ms),
                committed: acc.committed?
              )
            )
          )

          {:ok, finalize_stream_acc(acc)}

        {:http, {^request_id, {{_version, status, reason}, _headers, body}}}
        when status not in 200..299 ->
          retryable? = not acc.committed? and status in @retryable_stream_statuses

          VercelApiTrace.append_response_received(
            trace_context,
            "error",
            trace_meta
            |> Map.put(
              :response_summary,
              VercelApiTrace.response_summary(body,
                http_status: status,
                duration_ms: VercelApiTrace.duration_ms(started_at_ms),
                committed: acc.committed?,
                retryable: retryable?,
                reason: to_string(reason)
              )
            )
          )

          stream_http_error(status, reason, body, payload, acc.committed?)

        {:http, {^request_id, {:error, reason}}} ->
          trace_request_failure(
            trace_context,
            trace_meta,
            reason,
            started_at_ms,
            acc.committed?,
            retryable_stream_transport_error?(reason)
          )

          stream_transport_error(reason, acc.committed?)
      after
        request_timeout_ms() ->
          :httpc.cancel_request(request_id)

          trace_request_timeout(
            trace_context,
            trace_meta,
            started_at_ms,
            acc.committed?,
            not acc.committed?
          )

          stream_timeout_error(acc.committed?)
      end
    end
  end

  defp stream_transport_error(reason, committed?) do
    message = "AI Gateway stream failed: #{inspect(reason)}"

    if not committed? and retryable_stream_transport_error?(reason) do
      {:error, {:retryable_stream_failure, message}}
    else
      {:error, {:stream_failure, message}}
    end
  end

  defp stream_timeout_error(false), do: {:error, {:retryable_stream_failure, :timeout}}
  defp stream_timeout_error(true), do: {:error, {:stream_failure, :timeout}}

  defp stream_http_error(status, reason, body, payload, committed?) do
    message = gateway_error(status, reason, body, payload)

    if not committed? and status in @retryable_stream_statuses do
      {:error, {:retryable_stream_failure, message}}
    else
      {:error, {:stream_failure, message}}
    end
  end

  defp retryable_stream_transport_error?({:failed_connect, _reason}), do: true
  defp retryable_stream_transport_error?(reason), do: transient_stream_reason?(reason)

  defp trace_meta(opts, payload, transport, extra \\ []) do
    extra = Map.new(extra)
    summary_opts = value(extra, :summary_opts) || []

    request_summary =
      value(extra, :request_summary) || VercelApiTrace.request_summary(payload, summary_opts)

    %{
      trace_context: VercelApiTrace.context_from_opts(opts),
      transport: transport,
      model:
        value(payload, :model) || value(opts, :model) || value(opts, :image_model) ||
          value(opts, :text_model),
      stream: value(payload, :stream),
      request_summary: request_summary
    }
  end

  defp image_summary_opts(reference_images, mask_image, opts) do
    reference_count = length(List.wrap(reference_images || []))
    mask_present = not is_nil(mask_image)

    [
      reference_count: reference_count,
      mask_present: mask_present,
      file_count: reference_count + if(mask_present, do: 1, else: 0),
      image_options: image_option_fields(opts)
    ]
  end

  defp trace_request_meta(method, url, payload, trace_meta, attempt, max_attempts) do
    %{
      trace_context: value(trace_meta, :trace_context),
      transport: value(trace_meta, :transport) || "http_json",
      method: method |> to_string() |> String.upcase(),
      endpoint: VercelApiTrace.endpoint_path(url),
      model: value(trace_meta, :model) || value(payload, :model),
      stream: value(trace_meta, :stream) || value(payload, :stream),
      attempt: attempt,
      max_attempts: max_attempts,
      request_summary:
        value(trace_meta, :request_summary) ||
          VercelApiTrace.request_summary(payload, value(trace_meta, :summary_opts) || [])
    }
    |> compact()
  end

  defp trace_request_failure(
         trace_context,
         trace_meta,
         reason,
         started_at_ms,
         committed?,
         retryable?
       ) do
    if timeout_reason?(reason) do
      trace_request_timeout(trace_context, trace_meta, started_at_ms, committed?, retryable?)
    else
      VercelApiTrace.append_request_failed(
        trace_context,
        trace_meta
        |> Map.put(
          :error_summary,
          VercelApiTrace.transport_error_summary(reason,
            duration_ms: VercelApiTrace.duration_ms(started_at_ms),
            committed: committed?,
            retryable: retryable?
          )
        )
      )
    end
  end

  defp trace_request_timeout(trace_context, trace_meta, started_at_ms, committed?, retryable?) do
    VercelApiTrace.append_request_timeout(
      trace_context,
      trace_meta
      |> Map.put(
        :error_summary,
        VercelApiTrace.transport_error_summary(:timeout,
          duration_ms: VercelApiTrace.duration_ms(started_at_ms),
          committed: committed?,
          retryable: retryable?
        )
      )
    )
  end

  defp timeout_reason?(reason) when reason in [:timeout, :etimedout], do: true

  defp timeout_reason?(reason) when is_tuple(reason) do
    reason
    |> Tuple.to_list()
    |> Enum.any?(&timeout_reason?/1)
  end

  defp timeout_reason?(reason) when is_list(reason), do: Enum.any?(reason, &timeout_reason?/1)

  defp timeout_reason?(reason) when is_binary(reason) do
    reason
    |> String.downcase()
    |> String.contains?("timeout")
  end

  defp timeout_reason?(_reason), do: false

  defp transient_stream_reason?(reason)
       when reason in [
              :closed,
              :socket_closed_remotely,
              :econnreset,
              :econnrefused,
              :etimedout,
              :timeout,
              :enetunreach,
              :ehostunreach,
              :nxdomain
            ],
       do: true

  defp transient_stream_reason?(reason) when is_tuple(reason) do
    reason
    |> Tuple.to_list()
    |> Enum.any?(&transient_stream_reason?/1)
  end

  defp transient_stream_reason?(reason) when is_list(reason) do
    Enum.any?(reason, &transient_stream_reason?/1)
  end

  defp transient_stream_reason?(reason) when is_binary(reason) do
    reason = String.downcase(reason)

    Enum.any?(
      ["closed", "refused", "reset", "timedout", "timeout"],
      &String.contains?(reason, &1)
    )
  end

  defp transient_stream_reason?(_reason), do: false

  defp wait_for_stream_retry(backoff_ms, interrupted?) do
    do_wait_for_stream_retry(max(backoff_ms, 0), interrupted?)
  end

  defp do_wait_for_stream_retry(remaining_ms, interrupted?) do
    cond do
      interrupted?.() ->
        {:error, :interrupted}

      remaining_ms <= 0 ->
        :ok

      true ->
        sleep_ms = min(remaining_ms, @retry_sleep_interval_ms)
        Process.sleep(sleep_ms)
        do_wait_for_stream_retry(remaining_ms - sleep_ms, interrupted?)
    end
  end

  defp http_options do
    [
      timeout: request_timeout_ms(),
      connect_timeout: connect_timeout_ms()
    ]
  end

  defp request_timeout_ms do
    Application.get_env(:avcs, :avcs_agent_request_timeout_ms, @default_request_timeout_ms)
  end

  defp connect_timeout_ms do
    Application.get_env(:avcs, :avcs_agent_connect_timeout_ms, @default_connect_timeout_ms)
  end

  defp stream_retry_attempts do
    :avcs
    |> Application.get_env(:avcs_agent_stream_retry_attempts, @default_stream_retry_attempts)
    |> normalize_positive_integer(@default_stream_retry_attempts)
  end

  defp stream_retry_backoff_ms(attempt) do
    backoffs =
      :avcs
      |> Application.get_env(
        :avcs_agent_stream_retry_backoff_ms,
        @default_stream_retry_backoff_ms
      )
      |> normalize_backoff_ms()

    Enum.at(backoffs, attempt - 1) || List.last(backoffs) || 0
  end

  defp normalize_positive_integer(value, _default) when is_integer(value) and value > 0, do: value

  defp normalize_positive_integer(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} when integer > 0 -> integer
      _invalid -> default
    end
  end

  defp normalize_positive_integer(_value, default), do: default

  defp normalize_backoff_ms(values) when is_list(values) do
    values
    |> Enum.map(&normalize_non_negative_integer/1)
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_backoff_ms(value) do
    case normalize_non_negative_integer(value) do
      nil -> @default_stream_retry_backoff_ms
      integer -> [integer]
    end
  end

  defp normalize_non_negative_integer(value) when is_integer(value) and value >= 0, do: value

  defp normalize_non_negative_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} when integer >= 0 -> integer
      _invalid -> nil
    end
  end

  defp normalize_non_negative_integer(_value), do: nil

  defp consume_sse(buffer, acc, on_event) do
    parts = String.split(buffer, ~r/\r?\n\r?\n/, trim: false)
    {complete, [rest]} = Enum.split(parts, max(length(parts) - 1, 0))

    acc =
      Enum.reduce(complete, acc, fn event, acc ->
        event
        |> sse_data()
        |> handle_sse_data(acc, on_event)
      end)

    {rest || "", acc}
  end

  defp sse_data(event) do
    event
    |> String.split(~r/\r?\n/)
    |> Enum.filter(&String.starts_with?(&1, "data:"))
    |> Enum.map(fn "data:" <> data -> String.trim_leading(data) end)
    |> Enum.join("\n")
    |> String.trim()
  end

  defp handle_sse_data("", acc, _on_event), do: acc
  defp handle_sse_data("[DONE]", acc, _on_event), do: acc

  defp handle_sse_data(data, acc, on_event) do
    case Jason.decode(data) do
      {:ok, chunk} ->
        apply_stream_chunk(acc, chunk, on_event)

      {:error, _reason} ->
        acc
    end
  end

  defp apply_stream_chunk(acc, chunk, on_event) do
    choice = chunk |> Map.get("choices", []) |> List.first() || %{}
    delta = Map.get(choice, "delta", %{}) || %{}
    content = Map.get(delta, "content")
    tool_call_deltas = List.wrap(Map.get(delta, "tool_calls", []))

    acc =
      if is_binary(content) and content != "" do
        on_event.({:assistant_delta, content, chunk})
        %{acc | assistant_text: acc.assistant_text <> content}
      else
        acc
      end

    acc =
      tool_call_deltas
      |> Enum.reduce(acc, &merge_tool_call_delta/2)

    remote_model = chunk["model"] || acc.remote_model
    remote_turn_id = chunk["id"] || acc.remote_turn_id

    committed? =
      acc.committed? or (is_binary(content) and content != "") or tool_call_deltas != [] or
        present?(chunk["model"]) or present?(chunk["id"])

    %{acc | remote_model: remote_model, remote_turn_id: remote_turn_id, committed?: committed?}
  end

  defp merge_tool_call_delta(delta, acc) do
    index = delta["index"] || 0
    existing = Map.get(acc.tool_calls, index, %{"function" => %{}})
    function = existing["function"] || %{}
    delta_function = delta["function"] || %{}

    merged =
      existing
      |> put_if_present("id", delta["id"])
      |> put_if_present("type", delta["type"])
      |> Map.put(
        "function",
        function
        |> put_if_present("name", delta_function["name"])
        |> append_if_present("arguments", delta_function["arguments"])
      )

    %{acc | tool_calls: Map.put(acc.tool_calls, index, merged)}
  end

  defp parse_completion(json) do
    message =
      json
      |> Map.get("choices", [])
      |> List.first()
      |> case do
        %{"message" => message} -> message
        _choice -> %{}
      end

    %{
      assistant_text: message["content"] || "",
      tool_calls: normalize_tool_calls(message["tool_calls"] || []),
      remote_turn_id: json["id"],
      remote_model: json["model"]
    }
  end

  defp finalize_stream_acc(acc) do
    %{
      assistant_text: acc.assistant_text,
      tool_calls: normalize_tool_calls(acc.tool_calls |> Enum.sort() |> Enum.map(&elem(&1, 1))),
      remote_turn_id: acc.remote_turn_id,
      remote_model: acc.remote_model
    }
  end

  defp normalize_tool_calls(tool_calls) do
    Enum.map(tool_calls, fn call ->
      function = call["function"] || %{}

      %{
        "id" => call["id"] || "tool-call-" <> Ecto.UUID.generate(),
        "type" => call["type"] || "function",
        "name" => function["name"],
        "arguments" => function["arguments"] || "{}"
      }
    end)
  end

  defp images_from_response(json) do
    image_api_images =
      json
      |> Map.get("data", [])
      |> Enum.flat_map(&image_from_response/1)

    chat_images =
      json
      |> Map.get("choices", [])
      |> Enum.flat_map(&images_from_chat_choice/1)

    image_api_images ++ chat_images
  end

  defp images_from_chat_choice(%{"message" => %{"images" => images}}) when is_list(images) do
    Enum.flat_map(images, &image_from_response/1)
  end

  defp images_from_chat_choice(%{"message" => %{"content" => content}}) when is_list(content) do
    Enum.flat_map(content, &image_from_response/1)
  end

  defp images_from_chat_choice(_choice), do: []

  defp image_from_response(%{"b64_json" => b64}) when is_binary(b64) and b64 != "" do
    [%{base64: b64, mime_type: "image/png"}]
  end

  defp image_from_response(%{"image_url" => %{"url" => "data:" <> _rest = data_uri}}) do
    image_from_data_uri(data_uri)
  end

  defp image_from_response(%{"url" => "data:" <> _rest = data_uri}) do
    image_from_data_uri(data_uri)
  end

  defp image_from_response(%{"type" => "image_url", "image_url" => "data:" <> _rest = data_uri}) do
    image_from_data_uri(data_uri)
  end

  defp image_from_response(_image), do: []

  defp image_from_data_uri("data:" <> _rest = data_uri) do
    case String.split(data_uri, ",", parts: 2) do
      ["data:" <> meta, b64] ->
        mime_type = meta |> String.split(";") |> List.first()
        [%{base64: b64, mime_type: mime_type || "image/png"}]

      _parts ->
        []
    end
  end

  defp empty_stream_acc do
    %{
      assistant_text: "",
      tool_calls: %{},
      remote_turn_id: nil,
      remote_model: nil,
      committed?: false
    }
  end

  defp endpoint(settings, path) do
    settings.base_url
    |> String.trim_trailing("/")
    |> Kernel.<>(path)
  end

  defp gateway_error(status, reason, body, payload) do
    message =
      case Jason.decode(to_string(body || "")) do
        {:ok, %{"error" => %{"message" => message}}} when is_binary(message) -> message
        _result -> to_string(reason)
      end

    if chat_structured_image_payload?(payload) and structured_image_error?(status, message) do
      "AI Gateway/model rejected structured image input. Select a vision-capable OpenAI-compatible chat model or remove image references. HTTP #{status}: #{message}"
    else
      "AI Gateway request failed with HTTP #{status}: #{message}"
    end
  end

  defp chat_structured_image_payload?(payload) do
    contains_key?(payload, "image_url") and image_modality_payload?(payload)
  end

  defp image_modality_payload?(payload) do
    payload
    |> value(:modalities)
    |> List.wrap()
    |> Enum.any?(&(to_string(&1) == "image"))
  end

  defp contains_key?(%{} = map, target) do
    Enum.any?(map, fn {key, value} ->
      to_string(key) == target or contains_key?(value, target)
    end)
  end

  defp contains_key?(list, target) when is_list(list),
    do: Enum.any?(list, &contains_key?(&1, target))

  defp contains_key?(_value, _target), do: false

  defp structured_image_error?(status, message) when status in [400, 404, 415, 422] do
    message =
      message
      |> to_string()
      |> String.downcase()

    Enum.any?(
      ["image", "vision", "content", "unsupported", "invalid"],
      &String.contains?(message, &1)
    )
  end

  defp structured_image_error?(_status, _message), do: false

  defp require_api_key(%{api_key: api_key}) when is_binary(api_key) and api_key != "", do: :ok
  defp require_api_key(_settings), do: {:error, :avcs_agent_api_key_missing}

  defp ensure_http_started do
    _ = Application.ensure_all_started(:ssl)
    _ = Application.ensure_all_started(:inets)
    :ok
  end

  defp compact(map) do
    map
    |> Enum.reject(fn {_key, value} -> is_nil(value) or value == "" or value == [] end)
    |> Map.new()
  end

  defp put_if_present(map, _key, nil), do: map
  defp put_if_present(map, _key, ""), do: map
  defp put_if_present(map, key, value), do: Map.put(map, key, value)

  defp append_if_present(map, _key, nil), do: map
  defp append_if_present(map, _key, ""), do: map

  defp append_if_present(map, key, value) do
    Map.put(map, key, to_string(Map.get(map, key) || "") <> value)
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  defp value(opts, key) when is_list(opts), do: Keyword.get(opts, key)

  defp value(opts, key) when is_map(opts),
    do: Map.get(opts, key) || Map.get(opts, Atom.to_string(key))

  defp value(_opts, _key), do: nil
end
