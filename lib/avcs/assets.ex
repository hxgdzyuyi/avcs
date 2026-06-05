defmodule Avcs.Assets do
  @moduledoc false

  alias Avcs.Storage.SQLite

  @image_extensions ~w(.png .jpg .jpeg .gif .webp)
  @asset_delete_command "rm"
  @board_initial_x 72.0
  @board_initial_y 72.0
  @board_same_turn_gap 24.0
  @board_new_group_gap 72.0
  @board_max_group_width 1280.0

  def list_assets(project) do
    SQLite.with_db(Avcs.Projects.project_db_path(project), fn db ->
      SQLite.all!(db, "SELECT * FROM assets ORDER BY created_at DESC")
    end)
  end

  def get_asset(project, id) do
    SQLite.with_db(Avcs.Projects.project_db_path(project), fn db ->
      SQLite.one!(db, "SELECT * FROM assets WHERE id = ? LIMIT 1", [id])
    end)
  end

  def get_asset_by_hash(project, hash) do
    SQLite.with_db(Avcs.Projects.project_db_path(project), fn db ->
      SQLite.one!(db, "SELECT * FROM assets WHERE hash = ? LIMIT 1", [hash])
    end)
  end

  def resolve_reference_paths(project, asset_ids) when is_list(asset_ids) do
    asset_ids
    |> Enum.flat_map(fn id ->
      case get_asset(project, id) do
        {:ok, nil} -> []
        {:ok, asset} -> [asset]
        {:error, _reason} -> []
      end
    end)
    |> Enum.map(& &1["file_path"])
    |> Enum.filter(&File.exists?/1)
  end

  def delete_asset(project, id) when is_binary(id) do
    case get_asset(project, id) do
      {:ok, nil} ->
        {:error, :not_found}

      {:ok, asset} ->
        with {:ok, file_status} <- deletable_asset_path(project, asset),
             :ok <- delete_file_if_present(file_status),
             {:ok, _result} <- delete_asset_rows(project, asset["id"]) do
          {:ok, asset}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  def import_image(project, source_path, opts \\ []) do
    source_path = Path.expand(source_path)

    with :ok <- ensure_supported_image(source_path),
         {:ok, hash} <- file_hash(source_path) do
      source = Keyword.get(opts, :source, "import")
      opts = Keyword.put(opts, :source, source)

      case get_asset_by_hash(project, hash) do
        {:ok, nil} ->
          target_dir =
            if source == "generated",
              do: Avcs.Projects.output_dir(project),
              else: Avcs.Projects.work_dir(project)

          target_path = Path.join(target_dir, target_file_name(hash, source_path))

          if not File.exists?(target_path) do
            File.mkdir_p!(target_dir)
            File.cp!(source_path, target_path)
          end

          upsert_asset(project, target_path, opts)

        {:ok, asset} ->
          touch_existing_asset(project, asset, opts)

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def upload_image(project, %Plug.Upload{} = upload, opts \\ []) do
    with :ok <- ensure_supported_extension(upload.filename),
         {:ok, hash} <- file_hash(upload.path) do
      opts = Keyword.merge(opts, source: "upload")

      case get_asset_by_hash(project, hash) do
        {:ok, nil} ->
          target_dir = Avcs.Projects.work_dir(project)
          target_path = Path.join(target_dir, target_file_name(hash, upload.filename))

          if not File.exists?(target_path) do
            File.mkdir_p!(target_dir)
            File.cp!(upload.path, target_path)
          end

          upsert_asset(project, target_path, opts)

        {:ok, asset} ->
          touch_existing_asset(project, asset, opts)

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def create_mask_image(project, base_asset_id, %Plug.Upload{} = upload, opts \\ []) do
    with {:ok, base_asset} <- require_asset(project, base_asset_id),
         :ok <- ensure_png_file(upload.path),
         {:ok, mask_dimensions} <- require_dimensions(upload.path),
         :ok <- ensure_mask_dimensions(base_asset, mask_dimensions),
         {:ok, hash} <- file_hash(upload.path) do
      target_dir =
        Path.join([Avcs.Projects.folder_path(project), ".avcs", "cache", "temp", "masks"])

      target_path = Path.join(target_dir, mask_file_name(hash, base_asset, upload.filename))

      if not File.exists?(target_path) do
        File.mkdir_p!(target_dir)
        File.cp!(upload.path, target_path)
      end

      upsert_asset(
        project,
        target_path,
        Keyword.merge(opts,
          source: "mask",
          prompt: "Visual edit mask for #{base_asset["file_name"]}"
        )
      )
    end
  end

  def scan_project(project, opts \\ []) do
    sources =
      [
        {Avcs.Projects.work_dir(project), "scan"},
        {Avcs.Projects.output_dir(project), Keyword.get(opts, :output_source, "generated")}
      ]

    results =
      sources
      |> Enum.flat_map(fn {dir, source} ->
        dir
        |> image_files()
        |> Enum.map(&upsert_asset(project, &1, source: source))
      end)

    errors = Enum.filter(results, &match?({:error, _}, &1))
    assets = for {:ok, asset} <- results, do: asset

    if errors == [] do
      {:ok, assets}
    else
      {:error, inspect(errors)}
    end
  end

  def upsert_asset(project, file_path, opts \\ []) do
    file_path = Path.expand(file_path)

    with {:ok, relative_path} <- Avcs.Projects.relative_to_project(project, file_path),
         :ok <- ensure_supported_image(file_path),
         {:ok, hash} <- file_hash(file_path),
         {:ok, stat} <- File.stat(file_path) do
      SQLite.with_db(Avcs.Projects.project_db_path(project), fn db ->
        SQLite.transaction!(db, fn ->
          now = Avcs.Time.now_iso()
          source = Keyword.get(opts, :source, "scan")
          thread_id = Keyword.get(opts, :thread_id)
          turn_id = Keyword.get(opts, :turn_id)
          item_id = Keyword.get(opts, :item_id)
          prompt = Keyword.get(opts, :prompt)
          file_name = Path.basename(file_path)
          extension = file_path |> Path.extname() |> String.downcase() |> String.trim_leading(".")
          mime_type = mime_type(file_path)
          {width, height} = dimensions(file_path)

          existing = SQLite.one!(db, "SELECT * FROM assets WHERE hash = ? LIMIT 1", [hash])

          asset =
            if existing do
              SQLite.run!(
                db,
                """
                UPDATE assets
                SET updated_at = ?,
                    thread_id = COALESCE(thread_id, ?),
                    turn_id = COALESCE(turn_id, ?),
                    item_id = COALESCE(item_id, ?)
                WHERE id = ?
                """,
                [now, thread_id, turn_id, item_id, existing["id"]]
              )

              SQLite.one!(db, "SELECT * FROM assets WHERE id = ?", [existing["id"]])
            else
              id = Ecto.UUID.generate()

              SQLite.run!(
                db,
                """
                INSERT INTO assets (
                  id, file_path, relative_path, file_name, file_type, mime_type,
                  width, height, size_bytes, hash, source, prompt, thread_id, turn_id,
                  item_id, created_at, updated_at
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                [
                  id,
                  file_path,
                  relative_path,
                  file_name,
                  extension,
                  mime_type,
                  width,
                  height,
                  stat.size,
                  hash,
                  source,
                  prompt,
                  thread_id,
                  turn_id,
                  item_id,
                  now,
                  now
                ]
              )

              SQLite.one!(db, "SELECT * FROM assets WHERE id = ?", [id])
            end

          link_asset(db, asset["id"], thread_id, turn_id, item_id, source, now)
          ensure_output_board_item(db, asset, source, thread_id, turn_id, item_id, now)
          asset
        end)
      end)
    else
      {:error, :outside_project} -> {:error, "Image must live inside the current project"}
      {:error, reason} -> {:error, reason}
    end
  end

  def supported_image?(path) do
    path
    |> Path.extname()
    |> String.downcase()
    |> then(&(&1 in @image_extensions))
  end

  def mime_type(path) do
    case path |> Path.extname() |> String.downcase() do
      ".png" -> "image/png"
      ".jpg" -> "image/jpeg"
      ".jpeg" -> "image/jpeg"
      ".gif" -> "image/gif"
      ".webp" -> "image/webp"
      _ -> "application/octet-stream"
    end
  end

  def image_dimensions(path), do: dimensions(path)

  defp image_files(dir) do
    if File.dir?(dir) do
      dir
      |> Path.join("**/*")
      |> Path.wildcard()
      |> Enum.filter(&(File.regular?(&1) and supported_image?(&1)))
    else
      []
    end
  end

  defp deletable_asset_path(project, %{"file_path" => file_path})
       when is_binary(file_path) and file_path != "" do
    path = Path.expand(file_path)

    with {:ok, _relative_path} <- Avcs.Projects.relative_to_project(project, path) do
      cond do
        File.exists?(path) and File.regular?(path) ->
          {:ok, {:present, path}}

        File.exists?(path) ->
          {:error, "Asset path is not a single file"}

        true ->
          {:ok, {:missing, path}}
      end
    else
      {:error, :outside_project} -> {:error, "Asset file must live inside the current project"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp deletable_asset_path(_project, _asset), do: {:error, "Asset path is missing"}

  defp delete_file_if_present({:present, file_path}), do: rm_single_file(file_path)
  defp delete_file_if_present({:missing, _file_path}), do: :ok

  defp rm_single_file(file_path) do
    command = @asset_delete_command
    args = [file_path]

    with {:ok, ^command} <- delete_command(command),
         :ok <- require_single_file_arg(args) do
      case System.cmd(command, args, stderr_to_stdout: true) do
        {_output, 0} ->
          :ok

        {output, status} ->
          detail = output |> to_string() |> String.trim()
          {:error, "rm failed with exit #{status}: #{detail}"}
      end
    end
  end

  defp delete_command(@asset_delete_command = command) do
    if System.find_executable(command) do
      {:ok, command}
    else
      {:error, "rm command is unavailable"}
    end
  end

  defp delete_command(_command), do: {:error, "Asset delete command must be rm"}

  defp require_single_file_arg([file_path]) when is_binary(file_path) and file_path != "", do: :ok
  defp require_single_file_arg(_args), do: {:error, "Asset delete can remove only one file"}

  defp delete_asset_rows(project, asset_id) do
    SQLite.with_db(Avcs.Projects.project_db_path(project), fn db ->
      SQLite.transaction!(db, fn ->
        SQLite.run!(db, "DELETE FROM board_items WHERE asset_id = ?", [asset_id])
        SQLite.run!(db, "DELETE FROM asset_links WHERE asset_id = ?", [asset_id])
        SQLite.run!(db, "DELETE FROM assets WHERE id = ?", [asset_id])
        %{asset_id: asset_id}
      end)
    end)
  end

  defp ensure_supported_image(path) do
    with :ok <- ensure_supported_extension(path) do
      cond do
        File.exists?(path) and not File.regular?(path) ->
          {:error, "Image path is not a file"}

        File.exists?(path) ->
          :ok

        true ->
          {:error, "Image file does not exist"}
      end
    end
  end

  defp ensure_supported_extension(path) do
    if supported_image?(path), do: :ok, else: {:error, "Unsupported image format"}
  end

  defp require_asset(project, id) when is_binary(id) and id != "" do
    case get_asset(project, id) do
      {:ok, nil} -> {:error, "Base image was not found"}
      {:ok, asset} -> {:ok, asset}
      {:error, reason} -> {:error, reason}
    end
  end

  defp require_asset(_project, _id), do: {:error, "Base image is required"}

  defp ensure_png_file(path) do
    case File.read(path) do
      {:ok, <<0x89, "PNG", 13, 10, 26, 10, _rest::binary>>} -> :ok
      {:ok, _binary} -> {:error, "Mask must be a PNG image"}
      {:error, reason} -> {:error, "Cannot read mask image: #{inspect(reason)}"}
    end
  end

  defp require_dimensions(path) do
    case dimensions(path) do
      {width, height}
      when is_integer(width) and width > 0 and is_integer(height) and height > 0 ->
        {:ok, {width, height}}

      _dimensions ->
        {:error, "Mask dimensions could not be read"}
    end
  end

  defp ensure_mask_dimensions(base_asset, {mask_width, mask_height}) do
    base_width = numeric_or_default(base_asset["width"], 0)
    base_height = numeric_or_default(base_asset["height"], 0)

    cond do
      base_width <= 0 or base_height <= 0 ->
        :ok

      base_width == mask_width and base_height == mask_height ->
        :ok

      true ->
        {:error, "Mask dimensions must match the base image"}
    end
  end

  defp file_hash(path) do
    case File.read(path) do
      {:ok, binary} ->
        {:ok, :crypto.hash(:sha256, binary) |> Base.encode16(case: :lower)}

      {:error, reason} ->
        {:error, "Cannot read image: #{inspect(reason)}"}
    end
  end

  defp target_file_name(hash, source_path) do
    base =
      source_path
      |> Path.basename()
      |> String.replace(~r/[^A-Za-z0-9._-]+/, "-")
      |> String.trim("-")

    "#{String.slice(hash, 0, 16)}-#{base}"
  end

  defp mask_file_name(hash, base_asset, upload_name) do
    base =
      base_asset["file_name"]
      |> to_string()
      |> Path.rootname()
      |> String.replace(~r/[^A-Za-z0-9._-]+/, "-")
      |> String.trim("-")
      |> case do
        "" -> "image"
        value -> value
      end

    suffix =
      upload_name
      |> to_string()
      |> Path.rootname()
      |> String.replace(~r/[^A-Za-z0-9._-]+/, "-")
      |> String.trim("-")
      |> case do
        "" -> "mask"
        value -> value
      end

    "#{String.slice(hash, 0, 16)}-#{base}-#{suffix}.png"
  end

  defp touch_existing_asset(project, asset, opts) do
    SQLite.with_db(Avcs.Projects.project_db_path(project), fn db ->
      SQLite.transaction!(db, fn ->
        now = Avcs.Time.now_iso()
        source = Keyword.get(opts, :source, "scan")
        thread_id = Keyword.get(opts, :thread_id)
        turn_id = Keyword.get(opts, :turn_id)
        item_id = Keyword.get(opts, :item_id)

        SQLite.run!(
          db,
          """
          UPDATE assets
          SET updated_at = ?,
              thread_id = COALESCE(thread_id, ?),
              turn_id = COALESCE(turn_id, ?),
              item_id = COALESCE(item_id, ?)
          WHERE id = ?
          """,
          [now, thread_id, turn_id, item_id, asset["id"]]
        )

        asset = SQLite.one!(db, "SELECT * FROM assets WHERE id = ?", [asset["id"]])
        link_asset(db, asset["id"], thread_id, turn_id, item_id, source, now)
        ensure_output_board_item(db, asset, source, thread_id, turn_id, item_id, now)
        asset
      end)
    end)
  end

  defp link_asset(_db, _asset_id, nil, nil, nil, _source, _now), do: :ok

  defp link_asset(db, asset_id, thread_id, turn_id, item_id, source, now) do
    existing =
      SQLite.one!(
        db,
        """
        SELECT * FROM asset_links
        WHERE asset_id = ? AND COALESCE(thread_id, '') = COALESCE(?, '')
          AND COALESCE(turn_id, '') = COALESCE(?, '')
          AND COALESCE(item_id, '') = COALESCE(?, '')
        LIMIT 1
        """,
        [asset_id, thread_id, turn_id, item_id]
      )

    if is_nil(existing) do
      SQLite.run!(
        db,
        """
        INSERT INTO asset_links (id, asset_id, thread_id, turn_id, item_id, source, created_at)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        """,
        [Ecto.UUID.generate(), asset_id, thread_id, turn_id, item_id, source, now]
      )
    else
      if existing["invalidated_at"] do
        SQLite.run!(
          db,
          """
          UPDATE asset_links
          SET invalidated_at = NULL,
              invalidated_by_item_id = NULL
          WHERE id = ?
          """,
          [existing["id"]]
        )
      end
    end
  end

  defp ensure_output_board_item(db, asset, source, thread_id, turn_id, item_id, now) do
    if output_asset?(asset) do
      ensure_board_item(db, asset, source, thread_id, turn_id, item_id, now)
    end
  end

  defp ensure_board_item(db, asset, source, thread_id, turn_id, item_id, now) do
    existing =
      SQLite.one!(db, "SELECT * FROM board_items WHERE asset_id = ? LIMIT 1", [asset["id"]])

    if is_nil(existing) do
      width = numeric_or_default(asset["width"], 320)
      height = numeric_or_default(asset["height"], 240)
      display_width = width |> max(180) |> min(360)

      display_height =
        if width > 0, do: display_width * height / width, else: 240

      placement = new_board_item_placement(db, turn_id, display_width)

      SQLite.run!(
        db,
        """
        INSERT INTO board_items (
          id, asset_id, thread_id, turn_id, item_id, x, y, display_width,
          display_height, z_index, source, created_at, updated_at
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        [
          Ecto.UUID.generate(),
          asset["id"],
          thread_id,
          turn_id,
          item_id,
          placement.x,
          placement.y,
          display_width,
          display_height,
          placement.z_index,
          source,
          now,
          now
        ]
      )
    else
      if existing["invalidated_at"] do
        SQLite.run!(
          db,
          """
          UPDATE board_items
          SET thread_id = ?,
              turn_id = ?,
              item_id = ?,
              source = ?,
              invalidated_at = NULL,
              invalidated_by_item_id = NULL,
              updated_at = ?
          WHERE id = ?
          """,
          [thread_id, turn_id, item_id, source, now, existing["id"]]
        )
      end
    end
  end

  defp output_asset?(%{"relative_path" => "output/" <> _rest}), do: true
  defp output_asset?(_asset), do: false

  defp new_board_item_placement(db, turn_id, display_width) do
    items = active_output_board_items(db)
    same_turn = if present_id?(turn_id), do: same_turn_items(items, turn_id), else: []
    z_index = next_board_z_index(items)

    {x, y} =
      cond do
        items == [] ->
          {@board_initial_x, @board_initial_y}

        same_turn != [] ->
          same_turn_position(same_turn, display_width)

        true ->
          new_group_position(items)
      end

    %{x: x, y: y, z_index: z_index}
  end

  defp active_output_board_items(db) do
    SQLite.all!(
      db,
      """
      SELECT board_items.id,
             board_items.rowid AS rowid,
             board_items.turn_id,
             board_items.x,
             board_items.y,
             board_items.display_width,
             board_items.display_height,
             board_items.z_index,
             board_items.created_at
      FROM board_items
      JOIN assets ON assets.id = board_items.asset_id
      WHERE assets.relative_path LIKE 'output/%'
        AND board_items.invalidated_at IS NULL
      ORDER BY board_items.created_at ASC, board_items.rowid ASC
      """
    )
  end

  defp same_turn_items(items, turn_id), do: Enum.filter(items, &(&1["turn_id"] == turn_id))

  defp same_turn_position(items, display_width) do
    last_item = List.last(items)
    bounds = board_item_bounds(items)

    candidate_x =
      board_number(last_item, "x") + board_number(last_item, "display_width") +
        @board_same_turn_gap

    candidate_y = board_number(last_item, "y")

    if candidate_x + display_width - bounds.x > @board_max_group_width do
      {bounds.x, bounds.y + bounds.height + @board_same_turn_gap}
    else
      {candidate_x, candidate_y}
    end
  end

  defp new_group_position(items) do
    latest = List.last(items)

    latest_group =
      if present_id?(latest["turn_id"]) do
        same_turn_items(items, latest["turn_id"])
      else
        [latest]
      end

    bounds = board_item_bounds(latest_group)
    {bounds.x, bounds.y + bounds.height + @board_new_group_gap}
  end

  defp next_board_z_index(items) do
    items
    |> Enum.map(&board_integer(&1, "z_index"))
    |> Enum.max(fn -> 0 end)
    |> then(&(&1 + 1))
  end

  defp board_item_bounds(items) do
    left = items |> Enum.map(&board_number(&1, "x")) |> Enum.min()
    top = items |> Enum.map(&board_number(&1, "y")) |> Enum.min()

    right =
      items
      |> Enum.map(&(board_number(&1, "x") + board_number(&1, "display_width")))
      |> Enum.max()

    bottom =
      items
      |> Enum.map(&(board_number(&1, "y") + board_number(&1, "display_height")))
      |> Enum.max()

    %{x: left, y: top, width: max(1.0, right - left), height: max(1.0, bottom - top)}
  end

  defp board_number(row, key), do: numeric_or_default(row[key], 0) * 1.0

  defp board_integer(row, key) do
    case row[key] do
      value when is_integer(value) -> value
      value when is_number(value) -> trunc(value)
      _value -> 0
    end
  end

  defp present_id?(value), do: is_binary(value) and String.trim(value) != ""

  defp dimensions(path) do
    case File.read(path) do
      {:ok, <<0x89, "PNG", 13, 10, 26, 10, _len::32, "IHDR", width::32, height::32, _::binary>>} ->
        {width, height}

      {:ok, <<"GIF", _::binary-size(3), width::little-16, height::little-16, _::binary>>} ->
        {width, height}

      {:ok, <<"RIFF", _size::32-little, "WEBP", rest::binary>>} ->
        webp_dimensions(rest)

      {:ok, <<0xFF, 0xD8, rest::binary>>} ->
        jpeg_dimensions(rest)

      _ ->
        {nil, nil}
    end
  end

  defp jpeg_dimensions(<<0xFF, marker, _len::16, data::binary>>)
       when marker in [0xC0, 0xC1, 0xC2, 0xC3] do
    <<_precision, height::16, width::16, _::binary>> = data
    {width, height}
  end

  defp jpeg_dimensions(<<0xFF, marker, len::16, _segment::binary-size(len - 2), rest::binary>>)
       when marker != 0xDA do
    jpeg_dimensions(rest)
  end

  defp jpeg_dimensions(<<_byte, rest::binary>>), do: jpeg_dimensions(rest)
  defp jpeg_dimensions(_), do: {nil, nil}

  defp webp_dimensions(
         <<"VP8X", _chunk::32-little, _flags::binary-size(4), width_m1::24-little,
           height_m1::24-little, _::binary>>
       ) do
    {width_m1 + 1, height_m1 + 1}
  end

  defp webp_dimensions(
         <<"VP8 ", _chunk::32-little, _frame_tag::24, 0x9D, 0x01, 0x2A, width::little-16,
           height::little-16, _::binary>>
       ) do
    {Bitwise.band(width, 0x3FFF), Bitwise.band(height, 0x3FFF)}
  end

  defp webp_dimensions(_), do: {nil, nil}

  defp numeric_or_default(value, _default) when is_number(value), do: value
  defp numeric_or_default(_value, default), do: default
end
