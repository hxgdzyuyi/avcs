defmodule Avcs.Agent.VercelApiTrace do
  @moduledoc false

  require Logger

  @scope "vercel_api"
  @provider "vercel_ai_gateway"
  @agent_harness "avcs_agent"
  @error_preview_bytes 1_000

  def context_from_opts(opts) do
    opts_context = value(opts, :trace_context)

    opts_context
    |> merge_context(opts)
    |> normalize_context()
  end

  def append_request_sent(context, meta) do
    append_event(context, "request_sent", "sent", "outbound", meta)
  end

  def append_response_received(context, status, meta) when status in ["ok", "error"] do
    append_event(context, "response_received", status, "inbound", meta)
  end

  def append_request_failed(context, meta) do
    append_event(context, "request_failed", "error", "runtime", meta)
  end

  def append_request_timeout(context, meta) do
    append_event(context, "request_timeout", "timeout", "runtime", meta)
  end

  def append_request_interrupted(context, meta) do
    append_event(context, "request_interrupted", "interrupted", "runtime", meta)
  end

  def request_summary(payload, opts \\ []) do
    encoded_size =
      case Jason.encode(payload) do
        {:ok, json} -> byte_size(json)
        {:error, _reason} -> nil
      end

    %{
      request_size_bytes: encoded_size,
      message_count: payload |> value(:messages) |> list_count(),
      tool_count: payload |> value(:tools) |> list_count(0),
      image_count: count_image_inputs(payload),
      n: value(payload, :n),
      reference_count: value(opts, :reference_count),
      mask_present: value(opts, :mask_present),
      file_count: value(opts, :file_count),
      image_options: compact(value(opts, :image_options) || %{})
    }
    |> compact()
  end

  def multipart_request_summary(fields, files, opts \\ []) do
    %{
      field_count: fields |> map_size_safe(),
      file_count: length(List.wrap(files)),
      n: value(fields, "n") || value(fields, :n),
      reference_count: value(opts, :reference_count),
      mask_present: value(opts, :mask_present),
      image_options: compact(value(opts, :image_options) || %{})
    }
    |> compact()
  end

  def response_summary(body, opts \\ []) do
    json =
      body
      |> to_string()
      |> Jason.decode()
      |> case do
        {:ok, decoded} -> decoded
        {:error, _reason} -> %{}
      end

    %{
      http_status: value(opts, :http_status),
      duration_ms: value(opts, :duration_ms),
      committed: value(opts, :committed),
      retryable: value(opts, :retryable),
      remote_response_id: value(json, :id),
      response_model: value(json, :model),
      usage: value(json, :usage),
      image_count: count_response_images(json),
      error_message: error_message(json, value(opts, :reason))
    }
    |> compact()
  end

  def stream_response_summary(acc, opts \\ []) do
    %{
      http_status: value(opts, :http_status),
      duration_ms: value(opts, :duration_ms),
      committed: value(opts, :committed),
      retryable: value(opts, :retryable),
      remote_response_id: value(acc, :remote_turn_id),
      response_model: value(acc, :remote_model)
    }
    |> compact()
  end

  def transport_error_summary(reason, opts \\ []) do
    %{
      duration_ms: value(opts, :duration_ms),
      committed: value(opts, :committed),
      retryable: value(opts, :retryable),
      error_message: preview(inspect(reason))
    }
    |> compact()
  end

  def endpoint_path(url) do
    case URI.parse(to_string(url || "")) do
      %URI{path: path, query: nil} when is_binary(path) and path != "" -> path
      %URI{path: path, query: query} when is_binary(path) and path != "" -> path <> "?" <> query
      _uri -> to_string(url || "")
    end
  end

  def duration_ms(started_at_ms) when is_integer(started_at_ms) do
    max(System.monotonic_time(:millisecond) - started_at_ms, 0)
  end

  def duration_ms(_started_at_ms), do: nil

  defp append_event(context, event_name, status, direction, meta) do
    context = normalize_context(context)

    if context.project && present?(context.thread_id) do
      attrs = %{
        scope: @scope,
        event_name: event_name,
        thread_id: context.thread_id,
        turn_id: context.turn_id,
        agent_harness: @agent_harness,
        provider: @provider,
        model: value(meta, :model) || context.model,
        remote_thread_id: context.remote_thread_id,
        remote_turn_id: context.remote_turn_id,
        remote_item_id: context.remote_item_id,
        status: status,
        payload:
          %{
            direction: direction,
            transport: value(meta, :transport),
            method: value(meta, :method),
            endpoint: value(meta, :endpoint),
            model: value(meta, :model) || context.model,
            stream: value(meta, :stream),
            attempt: value(meta, :attempt),
            max_attempts: value(meta, :max_attempts),
            request_summary: value(meta, :request_summary),
            response_summary: value(meta, :response_summary),
            error_summary: value(meta, :error_summary)
          }
          |> compact()
      }

      case Avcs.Trace.append_event(context.project, attrs) do
        {:ok, _event} ->
          :ok

        {:error, reason} ->
          Logger.warning("Failed to append Vercel API trace event: #{inspect(reason)}")
          :ok

        _event ->
          :ok
      end
    else
      :ok
    end
  rescue
    exception ->
      Logger.warning("Failed to append Vercel API trace event: #{Exception.message(exception)}")
      :ok
  end

  defp merge_context(nil, opts), do: merge_context(%{}, opts)

  defp merge_context(context, opts) when is_map(context) do
    direct =
      %{
        project: value(opts, :project),
        thread_id: value(opts, :thread_id),
        turn_id: value(opts, :turn_id),
        remote_thread_id: value(opts, :remote_thread_id),
        remote_turn_id: value(opts, :remote_turn_id),
        remote_item_id: value(opts, :remote_item_id),
        model: value(opts, :model) || value(opts, :text_model) || value(opts, :image_model)
      }
      |> compact()

    Map.merge(context, direct)
  end

  defp merge_context(_context, opts), do: merge_context(%{}, opts)

  defp normalize_context(context) when is_map(context) do
    %{
      project: value(context, :project),
      thread_id: clean_string(value(context, :thread_id) || value(context, :avcs_thread_id)),
      turn_id: clean_string(value(context, :turn_id) || value(context, :avcs_turn_id)),
      remote_thread_id: clean_string(value(context, :remote_thread_id)),
      remote_turn_id: clean_string(value(context, :remote_turn_id)),
      remote_item_id:
        clean_string(value(context, :remote_item_id) || value(context, :tool_call_id)),
      model:
        clean_string(
          value(context, :model) || value(context, :text_model) || value(context, :image_model)
        )
    }
  end

  defp normalize_context(_context), do: normalize_context(%{})

  defp error_message(%{"error" => %{"message" => message}}, _reason) when is_binary(message),
    do: preview(message)

  defp error_message(_json, reason) when is_binary(reason), do: preview(reason)
  defp error_message(_json, reason) when is_atom(reason), do: Atom.to_string(reason)
  defp error_message(_json, nil), do: nil
  defp error_message(_json, reason), do: preview(inspect(reason))

  defp count_response_images(%{"data" => data}) when is_list(data) do
    Enum.count(data, &(value(&1, :b64_json) || value(&1, :url) || value(&1, :image_url)))
  end

  defp count_response_images(%{"choices" => choices}) when is_list(choices) do
    Enum.reduce(choices, 0, fn choice, count ->
      count + count_image_inputs(value(choice, :message))
    end)
  end

  defp count_response_images(_json), do: nil

  defp count_image_inputs(value) when is_map(value) do
    Enum.reduce(value, 0, fn {key, child}, count ->
      increment = if to_string(key) == "image_url", do: 1, else: 0
      count + increment + count_image_inputs(child)
    end)
  end

  defp count_image_inputs(value) when is_list(value) do
    Enum.reduce(value, 0, fn child, count -> count + count_image_inputs(child) end)
  end

  defp count_image_inputs(_value), do: 0

  defp map_size_safe(value) when is_map(value), do: map_size(value)
  defp map_size_safe(_value), do: nil

  defp list_count(value, default \\ nil)
  defp list_count(value, _default) when is_list(value), do: length(value)
  defp list_count(_value, default), do: default

  defp clean_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      clean -> clean
    end
  end

  defp clean_string(_value), do: nil

  defp preview(value) when is_binary(value) do
    if byte_size(value) > @error_preview_bytes do
      binary_part(value, 0, @error_preview_bytes) <> "\n[truncated]"
    else
      value
    end
  end

  defp preview(value), do: value

  defp compact(map) when is_map(map) do
    map
    |> Enum.reject(fn {_key, value} ->
      is_nil(value) or value == "" or value == [] or value == %{}
    end)
    |> Map.new()
  end

  defp compact(_value), do: %{}

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  defp value(opts, key) when is_list(opts), do: Keyword.get(opts, key)

  defp value(opts, key) when is_map(opts) and is_atom(key) do
    Map.get(opts, key) || Map.get(opts, Atom.to_string(key))
  end

  defp value(opts, key) when is_map(opts) and is_binary(key) do
    Map.get(opts, key)
  end

  defp value(_opts, _key), do: nil
end
