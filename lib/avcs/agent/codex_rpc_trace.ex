defmodule Avcs.Agent.CodexRpcTrace do
  @moduledoc false

  require Logger

  @scope "codex_rpc"
  @transport "stdio_jsonl"
  @line_preview_bytes 512

  def append_outbound(project, context, message, meta \\ %{}) do
    context = normalize_context(context)
    ids = codex_ids_from_message(message, context)

    append_event(project, context, %{
      scope: @scope,
      event_name: "request_sent",
      thread_id: context.thread_id,
      turn_id: context.turn_id,
      codex_thread_id: ids.codex_thread_id,
      codex_turn_id: ids.codex_turn_id,
      codex_item_id: ids.codex_item_id,
      status: "sent",
      payload: base_payload("outbound", message, meta),
      raw: message
    })
  end

  def append_inbound(project, context, %{"id" => _id, "error" => error} = message, meta) do
    context = normalize_context(context)
    ids = codex_ids_from_message(message, context)

    payload =
      "inbound"
      |> base_payload(message, meta)
      |> maybe_put("error_code", value(error, :code))
      |> maybe_put("error_message", value(error, :message))

    append_event(project, context, %{
      scope: @scope,
      event_name: "response_received",
      thread_id: context.thread_id,
      turn_id: context.turn_id,
      codex_thread_id: ids.codex_thread_id,
      codex_turn_id: ids.codex_turn_id,
      codex_item_id: ids.codex_item_id,
      status: "error",
      payload: payload,
      raw: message
    })
  end

  def append_inbound(project, context, %{"id" => _id} = message, meta) do
    context = normalize_context(context)
    ids = codex_ids_from_message(message, context)

    append_event(project, context, %{
      scope: @scope,
      event_name: "response_received",
      thread_id: context.thread_id,
      turn_id: context.turn_id,
      codex_thread_id: ids.codex_thread_id,
      codex_turn_id: ids.codex_turn_id,
      codex_item_id: ids.codex_item_id,
      status: "ok",
      payload: base_payload("inbound", message, meta),
      raw: message
    })
  end

  def append_inbound(project, context, %{"method" => _method} = message, meta) do
    context = normalize_context(context)
    ids = codex_ids_from_message(message, context)

    append_event(project, context, %{
      scope: @scope,
      event_name: "notification_received",
      thread_id: context.thread_id,
      turn_id: context.turn_id,
      codex_thread_id: ids.codex_thread_id,
      codex_turn_id: ids.codex_turn_id,
      codex_item_id: ids.codex_item_id,
      status: "received",
      payload: base_payload("inbound", message, meta),
      raw: message
    })
  end

  def append_inbound(_project, _context, _message, _meta), do: :ok

  def append_decode_failed(project, context, line, reason) do
    context = normalize_context(context)
    line = IO.iodata_to_binary(line)

    append_event(project, context, %{
      scope: @scope,
      event_name: "decode_failed",
      thread_id: context.thread_id,
      turn_id: context.turn_id,
      codex_thread_id: context.codex_thread_id,
      codex_turn_id: context.codex_turn_id,
      codex_item_id: context.codex_item_id,
      status: "error",
      payload: %{
        direction: "inbound",
        transport: @transport,
        reason: reason_to_string(reason),
        size_bytes: byte_size(line),
        sha256: sha256(line)
      },
      raw: %{
        line_preview: line_preview(line),
        size_bytes: byte_size(line),
        sha256: sha256(line)
      }
    })
  end

  def append_runtime_error(project, context, event_name, meta \\ %{}) do
    context = normalize_context(context)
    status = if to_string(event_name) == "request_timeout", do: "timeout", else: "error"

    append_event(project, context, %{
      scope: @scope,
      event_name: to_string(event_name),
      thread_id: context.thread_id,
      turn_id: context.turn_id,
      codex_thread_id: context.codex_thread_id,
      codex_turn_id: context.codex_turn_id,
      codex_item_id: context.codex_item_id,
      status: status,
      payload:
        %{
          direction: "runtime",
          transport: @transport,
          method: string_value(meta, :method),
          rpc_id: value(meta, :rpc_id),
          phase: string_value(meta, :phase),
          timer_kind: string_value(meta, :timer_kind),
          os_pid: value(meta, :os_pid),
          exit_status: value(meta, :exit_status),
          reason: string_value(meta, :reason)
        }
        |> compact(),
      raw: value(meta, :raw)
    })
  end

  def context_from_active(nil), do: normalize_context(nil)

  def context_from_active(active) when is_map(active) do
    active_context =
      %{
        project: value(active, :project),
        thread_id: value(active, :avcs_thread_id),
        turn_id: value(active, :avcs_turn_id),
        codex_thread_id: value(active, :thread_id),
        codex_turn_id: get_in_value(active, [:acc, :codex_turn_id]),
        codex_item_id: value(active, :codex_item_id)
      }
      |> compact()

    active
    |> value(:trace_context)
    |> merge_context(value(active, :request) |> request_context())
    |> merge_context(active_context)
    |> normalize_context()
  end

  def context_from_active(_active), do: normalize_context(nil)

  def codex_ids_from_message(message, fallback_context) do
    fallback_context = normalize_context(fallback_context)

    %{
      codex_thread_id:
        first_present([
          get_in_value(message, [:params, :threadId]),
          get_in_value(message, [:params, :thread, :id]),
          get_in_value(message, [:result, :thread, :id]),
          get_in_value(message, [:result, :threadId]),
          fallback_context.codex_thread_id
        ]),
      codex_turn_id:
        first_present([
          get_in_value(message, [:params, :turn, :id]),
          get_in_value(message, [:result, :turn, :id]),
          get_in_value(message, [:params, :turnId]),
          get_in_value(message, [:params, :expectedTurnId]),
          get_in_value(message, [:result, :turnId]),
          fallback_context.codex_turn_id
        ]),
      codex_item_id:
        first_present([
          get_in_value(message, [:params, :item, :id]),
          get_in_value(message, [:result, :item, :id]),
          get_in_value(message, [:params, :itemId]),
          fallback_context.codex_item_id
        ])
    }
  end

  defp append_event(project, context, attrs) do
    project = project || context.project

    if project && present?(attrs.thread_id) do
      case Avcs.Trace.append_event(project, attrs) do
        {:ok, _event} ->
          :ok

        {:error, reason} ->
          Logger.warning("Failed to append Codex RPC trace event: #{inspect(reason)}")
          :ok

        _event ->
          :ok
      end
    else
      :ok
    end
  rescue
    exception ->
      Logger.warning("Failed to append Codex RPC trace event: #{Exception.message(exception)}")
      :ok
  end

  defp base_payload(direction, message, meta) do
    %{
      direction: direction,
      transport: @transport,
      method: rpc_method(message, meta),
      rpc_id: rpc_id(message, meta),
      phase: string_value(meta, :phase),
      schema: string_value(meta, :schema)
    }
    |> compact()
  end

  defp rpc_method(message, meta) do
    first_present([
      value(message, :method),
      value(meta, :method)
    ])
  end

  defp rpc_id(message, meta) do
    case first_present([value(message, :id), value(meta, :rpc_id), value(meta, :id)]) do
      nil -> nil
      id -> id
    end
  end

  defp request_context(request) when is_map(request) do
    value(request, :trace_context)
  end

  defp request_context(_request), do: %{}

  defp normalize_context(context) when is_map(context) do
    %{
      project: value(context, :project),
      thread_id: clean_string(value(context, :thread_id) || value(context, :avcs_thread_id)),
      turn_id: clean_string(value(context, :turn_id) || value(context, :avcs_turn_id)),
      codex_thread_id: clean_string(value(context, :codex_thread_id)),
      codex_turn_id: clean_string(value(context, :codex_turn_id)),
      codex_item_id: clean_string(value(context, :codex_item_id))
    }
  end

  defp normalize_context(_context) do
    %{
      project: nil,
      thread_id: nil,
      turn_id: nil,
      codex_thread_id: nil,
      codex_turn_id: nil,
      codex_item_id: nil
    }
  end

  defp merge_context(left, right) do
    left = normalize_context(left)
    right = normalize_context(right)

    %{
      project: right.project || left.project,
      thread_id: right.thread_id || left.thread_id,
      turn_id: right.turn_id || left.turn_id,
      codex_thread_id: right.codex_thread_id || left.codex_thread_id,
      codex_turn_id: right.codex_turn_id || left.codex_turn_id,
      codex_item_id: right.codex_item_id || left.codex_item_id
    }
  end

  defp get_in_value(value, path) do
    Enum.reduce_while(path, value, fn key, acc ->
      case value(acc, key) do
        nil -> {:halt, nil}
        next -> {:cont, next}
      end
    end)
  end

  defp value(map, key) when is_map(map) do
    Map.get(map, key) ||
      Map.get(map, Atom.to_string(key)) ||
      Map.get(map, camelize_key(key))
  end

  defp value(list, key) when is_list(list) do
    Enum.find_value(list, fn
      {candidate, value} ->
        if key_match?(candidate, key), do: value

      _entry ->
        nil
    end)
  end

  defp value(_value, _key), do: nil

  defp key_match?(candidate, key) do
    candidate == key or candidate == key_string(key) or candidate == camelize_key(key)
  end

  defp key_string(key) when is_atom(key), do: Atom.to_string(key)
  defp key_string(key), do: to_string(key)

  defp camelize_key(key) when is_atom(key) do
    key
    |> Atom.to_string()
    |> camelize_key()
  end

  defp camelize_key(key) when is_binary(key) do
    case String.split(key, "_") do
      [single] ->
        single

      [first | rest] ->
        first <> Enum.map_join(rest, "", &String.capitalize/1)
    end
  end

  defp first_present(values), do: Enum.find(values, &present?/1)

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(nil), do: false
  defp present?(_value), do: true

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp compact(map) do
    map
    |> Enum.reject(fn {_key, value} -> is_nil(value) or value == "" end)
    |> Map.new()
  end

  defp string_value(map, key) do
    case value(map, key) do
      nil -> nil
      value when is_binary(value) -> value
      value -> to_string(value)
    end
  end

  defp clean_string(nil), do: nil

  defp clean_string(value) do
    value
    |> to_string()
    |> String.trim()
    |> case do
      "" -> nil
      clean -> clean
    end
  end

  defp reason_to_string(reason) when is_binary(reason), do: reason
  defp reason_to_string(reason), do: inspect(reason)

  defp line_preview(line) do
    size = min(byte_size(line), @line_preview_bytes)

    line
    |> binary_part(0, size)
    |> inspect(limit: @line_preview_bytes, printable_limit: @line_preview_bytes)
  end

  defp sha256(value) do
    :crypto.hash(:sha256, value)
    |> Base.encode16(case: :lower)
  end
end
