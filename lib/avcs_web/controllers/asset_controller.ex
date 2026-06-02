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
