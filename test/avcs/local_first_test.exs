defmodule Avcs.LocalFirstTest do
  use ExUnit.Case, async: false

  @png Base.decode64!(
         "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII="
       )

  setup do
    project_dir =
      Path.join(System.tmp_dir!(), "avcs-local-first-#{System.unique_integer([:positive])}")

    File.rm_rf!(project_dir)
    File.mkdir_p!(project_dir)

    {:ok, project} = Avcs.Projects.open_project(project_dir)

    on_exit(fn ->
      File.rm_rf!(project_dir)
    end)

    %{project: project, project_dir: project_dir}
  end

  test "scan deduplicates asset records and board placement survives project reopen", %{
    project: project,
    project_dir: project_dir
  } do
    File.write!(Path.join([project_dir, "work", "a.png"]), @png)
    File.write!(Path.join([project_dir, "work", "b.png"]), @png)

    assert {:ok, [_first, _second]} = Avcs.Assets.scan_project(project)
    assert {:ok, [asset]} = Avcs.Assets.list_assets(project)
    assert asset["hash"]

    assert {:ok, [board_item]} = Avcs.Board.list_items(project)
    assert board_item["asset_id"] == asset["id"]

    assert {:ok, moved} = Avcs.Board.move_item(project, board_item["id"], 123.5, 234.5)
    assert moved["x"] == 123.5
    assert moved["y"] == 234.5

    assert {:ok, resized} = Avcs.Board.resize_item(project, board_item["id"], 456, 321)
    assert resized["display_width"] == 456.0
    assert resized["display_height"] == 321.0

    assert {:ok, reopened} = Avcs.Projects.open_project(project_dir)
    assert {:ok, [persisted]} = Avcs.Board.list_items(reopened)
    assert persisted["x"] == 123.5
    assert persisted["y"] == 234.5
    assert persisted["display_width"] == 456.0
    assert persisted["display_height"] == 321.0
  end

  test "import and upload reuse an existing hash without copying another project file", %{
    project: project,
    project_dir: project_dir
  } do
    source_one =
      Path.join(System.tmp_dir!(), "avcs-source-#{System.unique_integer([:positive])}-one.png")

    source_two =
      Path.join(System.tmp_dir!(), "avcs-source-#{System.unique_integer([:positive])}-two.png")

    upload_path =
      Path.join(System.tmp_dir!(), "avcs-upload-#{System.unique_integer([:positive])}.bin")

    on_exit(fn ->
      File.rm(source_one)
      File.rm(source_two)
      File.rm(upload_path)
    end)

    File.write!(source_one, @png)
    File.write!(source_two, @png)
    File.write!(upload_path, @png)

    assert {:ok, imported} = Avcs.Assets.import_image(project, source_one)
    assert {:ok, imported_again} = Avcs.Assets.import_image(project, source_two)
    assert imported_again["id"] == imported["id"]

    assert {:ok, uploaded} =
             Avcs.Assets.upload_image(project, %Plug.Upload{
               path: upload_path,
               filename: "same-content.png",
               content_type: "image/png"
             })

    assert uploaded["id"] == imported["id"]
    assert {:ok, [asset]} = Avcs.Assets.list_assets(project)
    assert asset["id"] == imported["id"]

    copied_images =
      project_dir
      |> Path.join("work/*")
      |> Path.wildcard()
      |> Enum.filter(&File.regular?/1)

    assert length(copied_images) == 1
  end

  test "asset references resolve to existing local project paths", %{
    project: project,
    project_dir: project_dir
  } do
    image_path = Path.join([project_dir, "work", "reference.png"])
    File.write!(image_path, @png)

    assert {:ok, asset} = Avcs.Assets.upsert_asset(project, image_path, source: "scan")
    assert [^image_path] = Avcs.Assets.resolve_reference_paths(project, [asset["id"], "missing"])
  end

  test "threads and user turn items persist message text and image references", %{
    project: project,
    project_dir: project_dir
  } do
    image_path = Path.join([project_dir, "work", "reference.png"])
    File.write!(image_path, @png)
    assert {:ok, asset} = Avcs.Assets.upsert_asset(project, image_path, source: "scan")

    assert {:ok, first} = Avcs.Threads.create_thread(project, "Logo concepts")
    assert {:ok, second} = Avcs.Threads.create_thread(project, "Cover variants")
    assert {:ok, renamed} = Avcs.Threads.rename_thread(project, second["id"], "Cover edits")
    assert renamed["title"] == "Cover edits"

    assert {:ok, created} =
             Avcs.Turns.create_user_turn(project, first["id"], "Use this reference", [
               asset["id"]
             ])

    assert created["turn"]["thread_id"] == first["id"]
    assert created["item"]["content"] == "Use this reference"
    assert created["item"]["payload"]["asset_ids"] == [asset["id"]]

    assert {:ok, items} = Avcs.Turns.list_items(project, first["id"])
    assert Enum.any?(items, &(&1["id"] == created["item"]["id"]))

    assert {:ok, :ok} = Avcs.Threads.archive_thread(project, second["id"])
    assert {:ok, threads} = Avcs.Threads.list_threads(project)
    refute Enum.any?(threads, &(&1["id"] == second["id"]))
  end

  test "thread defaults and turn overrides persist model and sandbox settings", %{
    project: project
  } do
    assert {:ok, thread} = Avcs.Threads.create_thread(project, "Model settings")

    settings =
      Avcs.Threads.clean_settings(%{
        "model" => "gpt-5.1",
        "effort" => "high",
        "approval_policy" => "on-request",
        "sandbox_mode" => "danger-full-access"
      })

    assert {:ok, updated} = Avcs.Threads.update_settings(project, thread["id"], settings)
    assert updated["default_model"] == "gpt-5.1"
    assert updated["default_effort"] == "high"
    assert updated["default_approval_policy"] == "on-request"
    assert updated["default_sandbox_mode"] == "danger-full-access"

    assert {:ok, created} =
             Avcs.Turns.create_user_turn(
               project,
               thread["id"],
               "Use selected settings",
               [],
               settings
             )

    assert created["turn"]["model"] == "gpt-5.1"
    assert created["turn"]["effort"] == "high"
    assert created["turn"]["approval_policy"] == "on-request"
    assert created["turn"]["sandbox_mode"] == "danger-full-access"

    assert {:ok, [item]} = Avcs.Turns.list_items(project, thread["id"])
    assert item["turn_model"] == "gpt-5.1"
    assert item["turn_effort"] == "high"
    assert item["turn_sandbox_mode"] == "danger-full-access"
  end

  test "project path boundary rejects files outside the project folder", %{
    project: project,
    project_dir: project_dir
  } do
    outside = Path.expand(Path.join(project_dir, "../outside.png"))
    assert {:error, :outside_project} = Avcs.Projects.relative_to_project(project, outside)
  end

  test "project archive hides global index entry without deleting project files", %{
    project: project,
    project_dir: project_dir
  } do
    assert {:ok, archived} = Avcs.Projects.archive_project(project["id"])
    assert archived["archived_at"]

    assert {:ok, projects} = Avcs.Projects.list_projects()
    refute Enum.any?(projects, &(&1["id"] == project["id"]))
    assert File.dir?(project_dir)
    assert File.exists?(Path.join([project_dir, ".avcs", "project.sqlite3"]))

    assert {:ok, reopened} = Avcs.Projects.open_project(project_dir)
    assert reopened["id"] == project["id"]
    assert {:ok, projects} = Avcs.Projects.list_projects()
    assert Enum.any?(projects, &(&1["id"] == project["id"]))
  end

  test "project delete removes only the global sqlite reference", %{
    project: project,
    project_dir: project_dir
  } do
    assert {:ok, deleted} = Avcs.Projects.delete_project_reference(project["id"])
    assert deleted["id"] == project["id"]

    assert {:ok, projects} = Avcs.Projects.list_projects()
    refute Enum.any?(projects, &(&1["id"] == project["id"]))
    assert File.dir?(project_dir)
    assert File.exists?(Path.join([project_dir, ".avcs", "project.sqlite3"]))

    assert {:ok, reopened} = Avcs.Projects.open_project(project_dir)
    assert reopened["id"] != project["id"]
  end

  test "blank projects are created under the configured root with incremented names" do
    root =
      Path.join(System.tmp_dir!(), "avcs-blank-projects-#{System.unique_integer([:positive])}")

    previous_root = Application.get_env(:avcs, :blank_projects_dir)
    Application.put_env(:avcs, :blank_projects_dir, root)

    on_exit(fn ->
      if previous_root do
        Application.put_env(:avcs, :blank_projects_dir, previous_root)
      else
        Application.delete_env(:avcs, :blank_projects_dir)
      end

      File.rm_rf!(root)
    end)

    File.mkdir_p!(Path.join(root, "Campaign Board"))

    assert {:ok, first} = Avcs.Projects.create_blank_project("Campaign Board")
    assert first["folder_path"] == Path.join(root, "Campaign Board 2")
    assert File.exists?(Path.join([first["folder_path"], ".avcs", "project.sqlite3"]))

    assert {:ok, second} = Avcs.Projects.create_blank_project("Campaign Board")
    assert second["folder_path"] == Path.join(root, "Campaign Board 3")

    assert {:error, reason} = Avcs.Projects.create_blank_project("../outside")
    assert reason == "Project name cannot contain path separators"
  end
end
