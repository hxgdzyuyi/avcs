defmodule Avcs.Board do
  @moduledoc false

  alias Avcs.Storage.SQLite

  @min_object_size 64.0
  @update_fields [:x, :y, :display_width, :display_height, :z_index]

  def list_items(project) do
    SQLite.with_db(Avcs.Projects.project_db_path(project), fn db ->
      SQLite.all!(
        db,
        """
        SELECT board_items.*,
               assets.file_name,
               assets.relative_path,
               assets.mime_type,
               assets.width AS asset_width,
               assets.height AS asset_height,
               assets.source AS asset_source
        FROM board_items
        JOIN assets ON assets.id = board_items.asset_id
        WHERE assets.relative_path LIKE 'output/%'
        ORDER BY board_items.z_index ASC, board_items.created_at ASC
        """
      )
    end)
  end

  def move_item(project, id, x, y) do
    with {:ok, [item]} <- update_items(project, [%{"id" => id, "x" => x, "y" => y}]) do
      {:ok, item}
    end
  end

  def resize_item(project, id, width, height) do
    with {:ok, [item]} <-
           update_items(project, [
             %{"id" => id, "display_width" => width, "display_height" => height}
           ]) do
      {:ok, item}
    end
  end

  def update_items(_project, updates) when not is_list(updates),
    do: {:error, :invalid_board_item_update}

  def update_items(project, updates) do
    case SQLite.with_db(Avcs.Projects.project_db_path(project), fn db ->
           with {:ok, normalized} <- normalize_updates(updates),
                :ok <- ensure_output_items(db, normalized) do
             SQLite.transaction!(db, fn ->
               now = Avcs.Time.now_iso()
               Enum.each(normalized, &update_item!(db, &1, now))
               list_items!(db)
             end)
           end
         end) do
      {:ok, {:error, reason}} -> {:error, reason}
      {:ok, items} -> {:ok, items}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_updates([]), do: {:ok, []}

  defp normalize_updates(updates) do
    updates
    |> Enum.reduce_while({:ok, []}, fn update, {:ok, normalized} ->
      case normalize_update(update) do
        {:ok, item_update} -> {:cont, {:ok, [item_update | normalized]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_update(%{"id" => id} = update) when is_binary(id) and id != "" do
    attrs =
      @update_fields
      |> Enum.reduce_while(%{}, fn field, attrs ->
        key = Atom.to_string(field)

        if Map.has_key?(update, key) do
          case normalize_field_value(field, update[key]) do
            {:ok, value} -> {:cont, Map.put(attrs, field, value)}
            :error -> {:halt, :error}
          end
        else
          {:cont, attrs}
        end
      end)

    cond do
      attrs == :error -> {:error, :invalid_board_item_update}
      map_size(attrs) == 0 -> {:error, :invalid_board_item_update}
      true -> {:ok, %{id: id, attrs: attrs}}
    end
  end

  defp normalize_update(_update), do: {:error, :invalid_board_item_update}

  defp ensure_output_items(_db, []), do: :ok

  defp ensure_output_items(db, updates) do
    ids = Enum.map(updates, & &1.id)
    placeholders = ids |> Enum.map(fn _id -> "?" end) |> Enum.join(",")

    rows =
      SQLite.all!(
        db,
        """
        SELECT board_items.id
        FROM board_items
        JOIN assets ON assets.id = board_items.asset_id
        WHERE board_items.id IN (#{placeholders})
          AND assets.relative_path LIKE 'output/%'
        """,
        ids
      )

    found_ids = MapSet.new(rows, & &1["id"])

    if Enum.all?(ids, &MapSet.member?(found_ids, &1)) do
      :ok
    else
      {:error, :board_item_not_found}
    end
  end

  defp update_item!(db, %{id: id, attrs: attrs}, now) do
    fields = Map.keys(attrs)
    set_clause = fields |> Enum.map(&"#{&1} = ?") |> Enum.join(", ")
    values = Enum.map(fields, &Map.fetch!(attrs, &1))

    SQLite.run!(
      db,
      "UPDATE board_items SET #{set_clause}, updated_at = ? WHERE id = ?",
      values ++ [now, id]
    )
  end

  defp list_items!(db) do
    SQLite.all!(
      db,
      """
      SELECT board_items.*,
             assets.file_name,
             assets.relative_path,
             assets.mime_type,
             assets.width AS asset_width,
             assets.height AS asset_height,
             assets.source AS asset_source
      FROM board_items
      JOIN assets ON assets.id = board_items.asset_id
      WHERE assets.relative_path LIKE 'output/%'
      ORDER BY board_items.z_index ASC, board_items.created_at ASC
      """
    )
  end

  defp parse_number(value) when is_integer(value), do: {:ok, value * 1.0}
  defp parse_number(value) when is_float(value), do: {:ok, value}

  defp parse_number(value) when is_binary(value) do
    value = String.trim(value)

    case Float.parse(value) do
      {number, ""} -> {:ok, number}
      _other -> :error
    end
  end

  defp parse_number(_value), do: :error

  defp normalize_field_value(:z_index, value), do: parse_positive_integer(value)

  defp normalize_field_value(field, value) when field in [:display_width, :display_height] do
    with {:ok, number} <- parse_number(value) do
      {:ok, max(number, @min_object_size)}
    end
  end

  defp normalize_field_value(_field, value), do: parse_number(value)

  defp parse_positive_integer(value) when is_integer(value) and value > 0, do: {:ok, value}
  defp parse_positive_integer(value) when is_integer(value), do: :error

  defp parse_positive_integer(value) when is_binary(value) do
    value = String.trim(value)

    case Integer.parse(value) do
      {number, ""} when number > 0 -> {:ok, number}
      _other -> :error
    end
  end

  defp parse_positive_integer(_value), do: :error
end
