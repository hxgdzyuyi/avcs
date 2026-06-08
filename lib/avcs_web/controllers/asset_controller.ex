defmodule AvcsWeb.AssetController do
  use AvcsWeb, :controller

  alias AvcsWeb.ApiResponse

  def import(conn, %{"path" => path}) do
    with_project(conn, fn conn, project ->
      case Avcs.Assets.import_image(project, path) do
        {:ok, asset} ->
          broadcast_assets(project, asset)
          ApiResponse.ok(conn, asset)

        {:error, reason} ->
          ApiResponse.error(conn, 422, "asset_import_failed", to_string(reason))
      end
    end)
  end

  def upload(conn, %{"file" => upload}) do
    with_project(conn, fn conn, project ->
      case Avcs.Assets.upload_image(project, upload) do
        {:ok, asset} ->
          broadcast_assets(project, asset)
          ApiResponse.ok(conn, asset)

        {:error, reason} ->
          ApiResponse.error(conn, 422, "asset_upload_failed", to_string(reason))
      end
    end)
  end

  def upload_to_output(conn, %{"file" => upload} = params) do
    with_project(conn, fn conn, project ->
      opts = [x: params["x"], y: params["y"]]

      case Avcs.Assets.upload_image_to_output(project, upload, opts) do
        {:ok, result} ->
          broadcast_assets(project, result.asset)
          ApiResponse.ok(conn, result)

        {:error, :asset_not_copyable} ->
          ApiResponse.error(conn, 422, "asset_not_copyable", "Asset cannot be copied to Output")

        {:error, :invalid_output_placement} ->
          ApiResponse.error(
            conn,
            422,
            "asset_upload_to_output_failed",
            "Drop position is invalid"
          )

        {:error, reason} ->
          ApiResponse.error(conn, 422, "asset_upload_to_output_failed", to_string(reason))
      end
    end)
  end

  def upload_to_output(conn, _params) do
    ApiResponse.error(conn, 422, "asset_upload_to_output_failed", "Image file is required")
  end

  def mask(conn, %{"file" => upload, "base_asset_id" => base_asset_id}) do
    with_project(conn, fn conn, project ->
      case Avcs.Assets.create_mask_image(project, base_asset_id, upload) do
        {:ok, asset} ->
          broadcast_assets(project, asset)
          ApiResponse.ok(conn, asset)

        {:error, reason} ->
          ApiResponse.error(conn, 422, "asset_mask_failed", to_string(reason))
      end
    end)
  end

  def mask(conn, _params) do
    ApiResponse.error(conn, 422, "asset_mask_failed", "Mask image and base asset are required")
  end

  def scan(conn, _params) do
    with_project(conn, fn conn, project ->
      case Avcs.Assets.scan_project(project) do
        {:ok, assets} ->
          broadcast_assets(project, nil)
          ApiResponse.ok(conn, %{items: assets})

        {:error, reason} ->
          ApiResponse.error(conn, 422, "asset_scan_failed", to_string(reason))
      end
    end)
  end

  def copy_to_output(conn, %{"id" => id} = params) do
    with_project(conn, fn conn, project ->
      opts = [x: params["x"], y: params["y"]]

      case Avcs.Assets.copy_to_output(project, id, opts) do
        {:ok, result} ->
          broadcast_assets(project, result.asset)
          ApiResponse.ok(conn, result)

        {:error, :not_found} ->
          ApiResponse.error(conn, 404, "asset_not_found", "Asset was not found")

        {:error, :asset_file_missing} ->
          ApiResponse.error(conn, 404, "asset_file_missing", "Asset file is missing")

        {:error, :asset_not_copyable} ->
          ApiResponse.error(conn, 422, "asset_not_copyable", "Asset cannot be copied to Output")

        {:error, :invalid_output_placement} ->
          ApiResponse.error(conn, 422, "asset_copy_to_output_failed", "Drop position is invalid")

        {:error, reason} ->
          ApiResponse.error(conn, 422, "asset_copy_to_output_failed", to_string(reason))
      end
    end)
  end

  def preview(conn, %{"id" => id}) do
    with_project(conn, fn conn, project ->
      case Avcs.Assets.get_asset(project, id) do
        {:ok, nil} ->
          ApiResponse.error(conn, 404, "asset_not_found", "Asset was not found")

        {:ok, asset} ->
          if File.exists?(asset["file_path"]) do
            conn
            |> put_resp_content_type(asset["mime_type"], nil)
            |> send_file(200, asset["file_path"])
          else
            ApiResponse.error(conn, 404, "asset_file_missing", "Asset file is missing")
          end

        {:error, reason} ->
          ApiResponse.error(conn, 422, "asset_preview_failed", to_string(reason))
      end
    end)
  end

  def path(conn, %{"id" => id}) do
    with_project(conn, fn conn, project ->
      case Avcs.Assets.get_asset(project, id) do
        {:ok, nil} -> ApiResponse.error(conn, 404, "asset_not_found", "Asset was not found")
        {:ok, asset} -> ApiResponse.ok(conn, %{path: asset["file_path"]})
        {:error, reason} -> ApiResponse.error(conn, 422, "asset_path_failed", to_string(reason))
      end
    end)
  end

  def delete(conn, %{"id" => id}) do
    with_project(conn, fn conn, project ->
      case Avcs.Assets.delete_asset(project, id) do
        {:ok, asset} ->
          broadcast_assets(project, nil)
          ApiResponse.ok(conn, %{asset_id: asset["id"], path: asset["file_path"]})

        {:error, :not_found} ->
          ApiResponse.error(conn, 404, "asset_not_found", "Asset was not found")

        {:error, reason} ->
          ApiResponse.error(conn, 422, "asset_delete_failed", to_string(reason))
      end
    end)
  end

  def reveal(conn, %{"id" => id}) do
    with_project(conn, fn conn, project ->
      case Avcs.Assets.get_asset(project, id) do
        {:ok, nil} ->
          ApiResponse.error(conn, 404, "asset_not_found", "Asset was not found")

        {:ok, asset} ->
          if System.find_executable("open") do
            System.cmd("open", ["-R", asset["file_path"]])
          end

          ApiResponse.ok(conn, %{path: asset["file_path"]})

        {:error, reason} ->
          ApiResponse.error(conn, 422, "asset_reveal_failed", to_string(reason))
      end
    end)
  end

  defp with_project(conn, fun) do
    case Avcs.Projects.current_project() do
      nil -> ApiResponse.error(conn, 409, "no_project", "Open a project folder first")
      project -> fun.(conn, project)
    end
  end

  defp broadcast_assets(project, asset) do
    {:ok, assets} = Avcs.Assets.list_assets(project)
    {:ok, board_items} = Avcs.Board.list_items(project)
    if asset, do: Avcs.Events.broadcast("asset:created", %{asset: asset})
    Avcs.Events.broadcast("assets:updated", %{items: assets})
    Avcs.Events.broadcast("board:items", %{items: board_items})
  end
end
