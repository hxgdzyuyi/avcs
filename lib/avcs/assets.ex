defmodule Avcs.Assets do
  @moduledoc false

  alias Avcs.Storage.SQLite

  @image_extensions ~w(.png .jpg .jpeg .gif .webp)
  @asset_delete_command "rm"

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
          ensure_board_item(db, asset, source, thread_id, turn_id, item_id, now)
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
        ensure_board_item(db, asset, source, thread_id, turn_id, item_id, now)
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
        SELECT id FROM asset_links
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
    end
  end

  defp ensure_board_item(db, asset, source, thread_id, turn_id, item_id, now) do
    existing =
      SQLite.one!(db, "SELECT id FROM board_items WHERE asset_id = ? LIMIT 1", [asset["id"]])

    if is_nil(existing) do
      count = SQLite.scalar!(db, "SELECT COUNT(*) AS count FROM board_items") || 0
      width = numeric_or_default(asset["width"], 320)
      height = numeric_or_default(asset["height"], 240)
      display_width = width |> max(180) |> min(360)

      display_height =
        if width > 0, do: display_width * height / width, else: 240

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
          40 + rem(count * 44, 520),
          40 + rem(count * 32, 360),
          display_width,
          display_height,
          count + 1,
          source,
          now,
          now
        ]
      )
    end
  end

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
