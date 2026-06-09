defmodule Avcs.Agent.ContextCompaction do
  @moduledoc false

  @default_token_budget 6_000
  @recent_message_count 10

  def compact(messages, threshold, opts \\ []) when is_list(messages) do
    budget = token_budget(opts)
    trigger_tokens = max(1, trunc(budget * normalize_threshold(threshold)))
    total_tokens = estimate_tokens(messages)

    if total_tokens > trigger_tokens do
      {compacted, meta} = do_compact(messages, budget)

      {:ok, compacted,
       Map.merge(meta, %{compacted: true, total_tokens: total_tokens, budget: budget})}
    else
      {:ok, messages, %{compacted: false, total_tokens: total_tokens, budget: budget}}
    end
  end

  def estimate_tokens(messages) when is_list(messages) do
    messages
    |> Enum.map(&message_tokens/1)
    |> Enum.sum()
  end

  defp do_compact([system | rest], budget) do
    {older, recent} = Enum.split(rest, -@recent_message_count)
    summary = summary_message(older)
    compacted = [system, summary | recent]

    if estimate_tokens(compacted) > budget and length(recent) > 4 do
      {older_recent, recent} = Enum.split(recent, -4)
      summary = summary_message(older ++ older_recent)

      {[system, summary | recent],
       %{kept_recent_messages: 4, summarized_messages: length(older ++ older_recent)}}
    else
      {compacted, %{kept_recent_messages: length(recent), summarized_messages: length(older)}}
    end
  end

  defp do_compact(messages, _budget) do
    {older, recent} = Enum.split(messages, -@recent_message_count)

    {[summary_message(older) | recent],
     %{kept_recent_messages: length(recent), summarized_messages: length(older)}}
  end

  defp summary_message(messages) do
    %{
      "role" => "system",
      "content" => "Context compaction summary:\n" <> summarize_messages(messages),
      "avcs_kind" => "context_compaction"
    }
  end

  defp summarize_messages(messages) do
    messages
    |> Enum.map(&summary_line/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  defp summary_line(message) do
    role = message["role"] || "message"
    kind = message["avcs_kind"] || role

    cond do
      kind in ["tool_call", "tool_result"] ->
        "- #{kind}: #{String.slice(content_text(message["content"]), 0, 700)}"

      kind == "reference_asset" ->
        "- reference_asset: #{String.slice(content_text(message["content"]), 0, 500)}"

      kind == "board_context" ->
        "- board_context: #{String.slice(content_text(message["content"]), 0, 500)}"

      true ->
        "- #{role}: #{String.slice(content_text(message["content"]), 0, 600)}"
    end
  end

  defp message_tokens(message) when is_map(message),
    do: estimated_text_tokens(content_text(message["content"]))

  defp message_tokens(message), do: estimated_text_tokens(to_string(message))

  defp content_text(content) when is_binary(content), do: content

  defp content_text(content) when is_list(content) do
    content
    |> Enum.map(fn
      %{"type" => "text", "text" => text} -> text
      %{"type" => "image_url"} -> "[structured image input]"
      other -> inspect(other)
    end)
    |> Enum.join("\n")
  end

  defp content_text(content), do: to_string(content || "")

  defp estimated_text_tokens(text) do
    text
    |> to_string()
    |> String.length()
    |> Kernel./(4)
    |> Float.ceil()
    |> trunc()
  end

  defp token_budget(opts) do
    case value(opts, :context_token_budget) do
      value when is_integer(value) and value > 0 ->
        value

      value when is_binary(value) ->
        case Integer.parse(value) do
          {int, ""} when int > 0 -> int
          _parse -> @default_token_budget
        end

      _value ->
        @default_token_budget
    end
  end

  defp normalize_threshold(value) when is_number(value) and value > 0 and value <= 1, do: value
  defp normalize_threshold(value) when is_number(value) and value > 1, do: 1.0
  defp normalize_threshold(_value), do: 0.75

  defp value(opts, key) when is_map(opts),
    do: Map.get(opts, key) || Map.get(opts, Atom.to_string(key))

  defp value(opts, key) when is_list(opts), do: Keyword.get(opts, key)
  defp value(_opts, _key), do: nil
end
