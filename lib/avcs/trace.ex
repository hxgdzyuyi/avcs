defmodule Avcs.Trace do
  @moduledoc false

  alias Avcs.Storage.SQLite

  @base64_threshold_bytes 8 * 1024
  @long_string_threshold_bytes 64 * 1024
  @long_string_keep_bytes 16 * 1024
  @large_json_threshold_bytes 256 * 1024
  @known_large_string_keys MapSet.new([
                             "result",
                             "b64_json",
                             "b64json",
                             "base64",
                             "image_base64",
                             "imagebase64",
                             "audio_base64",
                             "audiobase64"
                           ])

  def append_event(project, attrs, opts \\ []) do
    db = Keyword.get(opts, :db)

    if db do
      append_event_to_db(db, attrs)
    else
      SQLite.with_db(Avcs.Projects.project_db_path(project), fn db ->
        append_event_to_db(db, attrs)
      end)
    end
  end

  def list_events(project, thread_id, opts \\ []) when is_binary(thread_id) do
    SQLite.with_db(Avcs.Projects.project_db_path(project), fn db ->
      turn_id = Keyword.get(opts, :turn_id) || attr(opts, :turn_id)

      {sql, params} =
        if is_binary(turn_id) and turn_id != "" do
          {
            """
            SELECT *
            FROM trace_events
            WHERE thread_id = ? AND turn_id = ?
            ORDER BY created_at ASC
            """,
            [thread_id, turn_id]
          }
        else
          {
            """
            SELECT *
            FROM trace_events
            WHERE thread_id = ?
            ORDER BY created_at ASC
            """,
            [thread_id]
          }
        end

      db
      |> SQLite.all!(sql, params)
      |> Enum.map(&decode_event/1)
    end)
  end

  def sanitize_payload(value, root \\ "payload") do
    {sanitized, omitted} = sanitize_value(value, [root], nil)
    fit_json_size(sanitized, omitted, root)
  end

  defp append_event_to_db(db, attrs) do
    now = Avcs.Time.now_iso()
    id = attr(attrs, :id) || Ecto.UUID.generate()
    payload = attr(attrs, :payload) || %{}
    raw = attr(attrs, :raw)
    {payload, payload_omitted} = sanitize_payload(payload, "payload")
    {raw, raw_omitted} = sanitize_payload(raw, "raw")
    omitted = payload_omitted ++ raw_omitted

    SQLite.run!(
      db,
      """
      INSERT INTO trace_events (
        id, scope, event_name, thread_id, turn_id, item_id, codex_thread_id,
        codex_turn_id, codex_item_id, status, payload, raw, omitted, created_at
      )
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      """,
      [
        id,
        attr(attrs, :scope),
        attr(attrs, :event_name),
        attr(attrs, :thread_id),
        attr(attrs, :turn_id),
        attr(attrs, :item_id),
        attr(attrs, :codex_thread_id),
        attr(attrs, :codex_turn_id),
        attr(attrs, :codex_item_id),
        attr(attrs, :status),
        Jason.encode!(payload),
        encode_nullable(raw),
        Jason.encode!(omitted),
        now
      ]
    )

    decode_event(SQLite.one!(db, "SELECT * FROM trace_events WHERE id = ? LIMIT 1", [id]))
  end

  defp sanitize_value(value, path, _key) when is_map(value) do
    Enum.reduce(value, {%{}, []}, fn {child_key, child_value}, {acc, omitted} ->
      {clean, child_omitted} =
        sanitize_value(child_value, path ++ [to_string(child_key)], child_key)

      {Map.put(acc, child_key, clean), omitted ++ child_omitted}
    end)
  end

  defp sanitize_value(value, path, _key) when is_list(value) do
    value
    |> Enum.with_index()
    |> Enum.reduce({[], []}, fn {child_value, index}, {acc, omitted} ->
      {clean, child_omitted} = sanitize_value(child_value, path ++ ["[#{index}]"], nil)
      {[clean | acc], omitted ++ child_omitted}
    end)
    |> then(fn {items, omitted} -> {Enum.reverse(items), omitted} end)
  end

  defp sanitize_value(value, path, key) when is_binary(value) do
    cond do
      data_uri_base64?(value) ->
        summarize_large_string(value, path, "data_uri_base64")

      known_large_key?(key) and byte_size(value) > @base64_threshold_bytes ->
        summarize_large_string(value, path, "known_large_field")

      byte_size(value) > @base64_threshold_bytes and likely_base64?(value) ->
        summarize_large_string(value, path, "base64_like")

      byte_size(value) > @long_string_threshold_bytes ->
        truncated = binary_part(value, 0, min(byte_size(value), @long_string_keep_bytes))

        {
          truncated <> "\n[truncated]",
          [
            omitted_entry(path, "long_string_truncated", value)
            |> Map.put("kept_bytes", byte_size(truncated))
          ]
        }

      true ->
        {value, []}
    end
  end

  defp sanitize_value(value, _path, _key), do: {value, []}

  defp fit_json_size(value, omitted, root) do
    encoded = Jason.encode!(value)

    if byte_size(encoded) > @large_json_threshold_bytes do
      summary = %{
        "omitted" => true,
        "reason" => "json_too_large",
        "size_bytes" => byte_size(encoded),
        "sha256" => sha256(encoded),
        "omitted_count" => length(omitted),
        "path" => root
      }

      {summary, [Map.delete(summary, "omitted_count") | omitted]}
    else
      {value, omitted}
    end
  end

  defp summarize_large_string(value, path, reason) do
    {
      %{
        "omitted" => true,
        "reason" => reason,
        "size_bytes" => byte_size(value),
        "sha256" => sha256(value),
        "preview" => String.slice(value, 0, 96)
      },
      [omitted_entry(path, reason, value)]
    }
  end

  defp omitted_entry(path, reason, value) do
    %{
      "path" => path_to_string(path),
      "reason" => reason,
      "size_bytes" => byte_size(value),
      "sha256" => sha256(value)
    }
  end

  defp known_large_key?(key) when is_atom(key), do: known_large_key?(Atom.to_string(key))

  defp known_large_key?(key) when is_binary(key) do
    key
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "_")
    |> then(&MapSet.member?(@known_large_string_keys, &1))
  end

  defp known_large_key?(_key), do: false

  defp data_uri_base64?(value) do
    String.starts_with?(value, "data:") and String.contains?(value, ";base64,")
  end

  defp likely_base64?(value) do
    clean = String.replace(value, ~r/\s+/, "")

    byte_size(clean) > @base64_threshold_bytes and rem(byte_size(clean), 4) == 0 and
      String.match?(clean, ~r/\A[A-Za-z0-9+\/_-]+={0,2}\z/)
  end

  defp sha256(value) do
    :crypto.hash(:sha256, value)
    |> Base.encode16(case: :lower)
  end

  defp path_to_string([root | rest]) do
    Enum.reduce(rest, to_string(root), fn
      "[" <> _ = part, acc -> acc <> part
      part, acc -> acc <> "." <> to_string(part)
    end)
  end

  defp encode_nullable(nil), do: nil
  defp encode_nullable(value), do: Jason.encode!(value)

  defp decode_event(nil), do: nil

  defp decode_event(event) do
    event
    |> Map.update("payload", %{}, &decode_json(&1, %{}))
    |> Map.update("raw", nil, &decode_json(&1, nil))
    |> Map.update("omitted", [], &decode_json(&1, []))
  end

  defp decode_json(nil, fallback), do: fallback
  defp decode_json("", fallback), do: fallback

  defp decode_json(value, fallback) do
    case Jason.decode(value) do
      {:ok, decoded} -> decoded
      {:error, _reason} -> fallback
    end
  end

  defp attr(attrs, key) when is_list(attrs), do: Keyword.get(attrs, key)

  defp attr(attrs, key) when is_map(attrs) do
    Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))
  end
end
