defmodule AvcsWeb.AssetControllerTest do
  use AvcsWeb.ConnCase

  @png Base.decode64!(
         "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII="
       )
  @png_alt Base.decode64!(
             "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADUlEQVR42mP8z8BQDwAFgwJ/lK3teQAAAABJRU5ErkJggg=="
           )

  setup do
    project_dir =
      Path.join(System.tmp_dir!(), "avcs-assets-#{System.unique_integer([:positive])}")

    File.rm_rf!(project_dir)
    {:ok, project} = Avcs.Projects.open_project(project_dir)

    on_exit(fn ->
      File.rm_rf!(project_dir)
    end)

    %{project: project, project_dir: project_dir}
  end

  test "multipart upload stores an image in work and returns a reusable asset", %{
    conn: conn,
    project: project,
    project_dir: project_dir
  } do
    upload_path =
      Path.join(System.tmp_dir!(), "avcs-upload-#{System.unique_integer([:positive])}.png")

    File.write!(upload_path, @png)

    conn =
      post(conn, ~p"/api/assets/upload", %{
        "file" => %Plug.Upload{
          path: upload_path,
          filename: "uploaded.png",
          content_type: "image/png"
        }
      })

    assert %{"success" => true, "data" => asset} = json_response(conn, 200)
    assert asset["source"] == "upload"
    assert asset["relative_path"] =~ "work/"
    assert File.exists?(asset["file_path"])
    assert String.starts_with?(asset["file_path"], Path.join(project_dir, "work"))
    assert {:ok, []} = Avcs.Board.list_items(project)

    File.rm(upload_path)
  end

  test "preview, path and scan endpoints use the API envelope", %{
    conn: conn,
    project: project,
    project_dir: project_dir
  } do
    image_path = Path.join([project_dir, "work", "scan-me.png"])
    File.write!(image_path, @png)

    scan_conn = post(conn, ~p"/api/assets/scan", %{})
    assert %{"success" => true, "data" => %{"items" => [_asset]}} = json_response(scan_conn, 200)
    assert {:ok, []} = Avcs.Board.list_items(project)

    {:ok, [asset]} = Avcs.Assets.list_assets(project)

    path_conn = get(build_conn(), ~p"/api/assets/#{asset["id"]}/path")

    assert %{"success" => true, "data" => %{"path" => ^image_path}} =
             json_response(path_conn, 200)

    preview_conn = get(build_conn(), ~p"/api/assets/#{asset["id"]}/preview")
    assert response(preview_conn, 200) == @png
    assert get_resp_header(preview_conn, "content-type") == ["image/png"]
  end

  test "mask upload stores a hidden mask asset inside project cache", %{
    conn: conn,
    project: project,
    project_dir: project_dir
  } do
    base_path = Path.join([project_dir, "output", "base.png"])
    File.write!(base_path, @png)
    assert {:ok, base_asset} = Avcs.Assets.upsert_asset(project, base_path, source: "generated")

    upload_path =
      Path.join(System.tmp_dir!(), "avcs-mask-#{System.unique_integer([:positive])}.png")

    File.write!(upload_path, @png_alt)

    conn =
      post(conn, ~p"/api/assets/mask", %{
        "base_asset_id" => base_asset["id"],
        "file" => %Plug.Upload{
          path: upload_path,
          filename: "mask.png",
          content_type: "image/png"
        }
      })

    assert %{"success" => true, "data" => mask_asset} = json_response(conn, 200)
    assert mask_asset["source"] == "mask"
    assert mask_asset["mime_type"] == "image/png"
    assert mask_asset["relative_path"] =~ ".avcs/cache/temp/masks/"
    assert File.exists?(mask_asset["file_path"])

    assert {:ok, [_base_board_item]} = Avcs.Board.list_items(project)
    assert {:ok, assets} = Avcs.Assets.list_assets(project)
    assert Enum.any?(assets, &(&1["id"] == mask_asset["id"]))

    File.rm(upload_path)
  end

  test "delete endpoint removes one asset file and clears board state", %{
    conn: conn,
    project: project,
    project_dir: project_dir
  } do
    image_path = Path.join([project_dir, "output", "delete-me.png"])
    File.write!(image_path, @png)

    assert {:ok, asset} = Avcs.Assets.upsert_asset(project, image_path, source: "generated")
    assert {:ok, [_board_item]} = Avcs.Board.list_items(project)

    asset_id = asset["id"]
    delete_conn = delete(conn, ~p"/api/assets/#{asset_id}")

    assert %{
             "success" => true,
             "data" => %{"asset_id" => ^asset_id, "path" => ^image_path}
           } = json_response(delete_conn, 200)

    refute File.exists?(image_path)
    assert {:ok, []} = Avcs.Assets.list_assets(project)
    assert {:ok, []} = Avcs.Board.list_items(project)
  end

  test "delete endpoint clears stale asset state when the file is already missing", %{
    conn: conn,
    project: project,
    project_dir: project_dir
  } do
    image_path = Path.join([project_dir, "output", "stale.png"])
    File.write!(image_path, @png)

    assert {:ok, asset} = Avcs.Assets.upsert_asset(project, image_path, source: "generated")
    File.rm!(image_path)

    asset_id = asset["id"]
    delete_conn = delete(conn, ~p"/api/assets/#{asset_id}")

    assert %{
             "success" => true,
             "data" => %{"asset_id" => ^asset_id, "path" => ^image_path}
           } = json_response(delete_conn, 200)

    refute File.exists?(image_path)
    assert {:ok, []} = Avcs.Assets.list_assets(project)
    assert {:ok, []} = Avcs.Board.list_items(project)
  end
end
