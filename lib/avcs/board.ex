defmodule Avcs.Board do
  @moduledoc false

  alias Avcs.Storage.SQLite

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
        ORDER BY board_items.z_index ASC, board_items.created_at ASC
        """
      )
    end)
  end

  def move_item(project, id, x, y) do
    update_item(project, id, %{x: to_number(x), y: to_number(y)})
  end

  def resize_item(project, id, width, height) do
    update_item(project, id, %{
      display_width: max(to_number(width), 48),
      display_height: max(to_number(height), 48)
    })
  end

  defp update_item(project, id, attrs) do
    SQLite.with_db(Avcs.Projects.project_db_path(project), fn db ->
      now = Avcs.Time.now_iso()

      Enum.each(attrs, fn {field, value} ->
        SQLite.run!(db, "UPDATE board_items SET #{field} = ?, updated_at = ? WHERE id = ?", [
          value,
          now,
          id
        ])
      end)

      SQLite.one!(
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
        WHERE board_items.id = ?
        LIMIT 1
        """,
        [id]
      )
    end)
  end

  defp to_number(value) when is_integer(value), do: value * 1.0
  defp to_number(value) when is_float(value), do: value

  defp to_number(value) when is_binary(value) do
    case Float.parse(value) do
      {number, _rest} -> number
      :error -> 0.0
    end
  end

  defp to_number(_value), do: 0.0
end
