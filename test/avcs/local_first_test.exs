defmodule Avcs.LocalFirstTest do
  use ExUnit.Case, async: false

  @png Base.decode64!(
         "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII="
       )

  @gif Base.decode64!("R0lGODlhAQABAPAAAP///wAAACH5BAAAAAAALAAAAAABAAEAAAICRAEAOw==")
  @png_alt Base.decode64!(
             "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADUlEQVR42mP8z8BQDwAFgwJ/lK3teQAAAABJRU5ErkJggg=="
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

  test "scan keeps work assets off board and output placement survives project reopen", %{
    project: project,
    project_dir: project_dir
  } do
    File.write!(Path.join([project_dir, "work", "a.png"]), @png)
    File.write!(Path.join([project_dir, "work", "b.png"]), @png)
    File.write!(Path.join([project_dir, "output", "generated.gif"]), @gif)

    assert {:ok, scan_results} = Avcs.Assets.scan_project(project)
    assert length(scan_results) == 3
    assert {:ok, assets} = Avcs.Assets.list_assets(project)
    assert length(assets) == 2
    assert Enum.any?(assets, &String.starts_with?(&1["relative_path"], "work/"))
    assert output_asset = Enum.find(assets, &String.starts_with?(&1["relative_path"], "output/"))

    assert {:ok, [board_item]} = Avcs.Board.list_items(project)
    assert board_item["asset_id"] == output_asset["id"]
    assert String.starts_with?(board_item["relative_path"], "output/")

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

  test "batch board item updates only output items and clamps object size", %{
    project: project,
    project_dir: project_dir
  } do
    File.write!(Path.join([project_dir, "output", "one.png"]), @png)
    File.write!(Path.join([project_dir, "output", "two.png"]), @png_alt)

    assert {:ok, _scan_results} = Avcs.Assets.scan_project(project)
    assert {:ok, board_items} = Avcs.Board.list_items(project)
    assert length(board_items) == 2
    [first, second] = board_items

    assert {:ok, updated} =
             Avcs.Board.update_items(project, [
               %{"id" => first["id"], "x" => 11, "y" => "22.5"},
               %{
                 "id" => second["id"],
                 "x" => 33,
                 "display_width" => 12,
                 "display_height" => 48
               }
             ])

    assert length(updated) == 2
    assert moved = Enum.find(updated, &(&1["id"] == first["id"]))
    assert resized = Enum.find(updated, &(&1["id"] == second["id"]))
    assert moved["x"] == 11.0
    assert moved["y"] == 22.5
    assert resized["x"] == 33.0
    assert resized["display_width"] == 64.0
    assert resized["display_height"] == 64.0

    assert {:error, :invalid_board_item_update} =
             Avcs.Board.update_items(project, [%{"id" => first["id"], "x" => "bad"}])

    assert {:error, :board_item_not_found} =
             Avcs.Board.update_items(project, [%{"id" => Ecto.UUID.generate(), "x" => 1}])
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

  test "turn item pages load latest, before, after, and around windows", %{
    project: project
  } do
    assert {:ok, thread} = Avcs.Threads.create_thread(project, "Paged thread")

    turns =
      for index <- 1..5 do
        assert {:ok, created} =
                 Avcs.Turns.create_user_turn(project, thread["id"], "Turn #{index}", [])

        set_turn_time(project, created["turn"]["id"], index)
        created
      end

    assert {:ok, latest} = Avcs.Turns.list_item_page(project, thread["id"], %{"limit" => 2})
    assert Enum.map(latest.items, & &1["content"]) == ["Turn 4", "Turn 5"]
    assert latest.page.mode == "latest"
    assert latest.page.turn_count == 2
    assert latest.page.has_more_before == true
    assert latest.page.has_more_after == false
    assert latest.page.at_latest == true

    assert {:ok, before} =
             Avcs.Turns.list_item_page(project, thread["id"], %{
               "limit" => 2,
               "before" => latest.page.before_cursor
             })

    assert Enum.map(before.items, & &1["content"]) == ["Turn 2", "Turn 3"]
    assert before.page.has_more_before == true
    assert before.page.has_more_after == true

    assert {:ok, after_page} =
             Avcs.Turns.list_item_page(project, thread["id"], %{
               "limit" => 2,
               "after" => before.page.after_cursor
             })

    assert Enum.map(after_page.items, & &1["content"]) == ["Turn 4", "Turn 5"]
    assert after_page.page.has_more_after == false
    assert after_page.page.at_latest == true

    anchor_turn_id = Enum.at(turns, 2)["turn"]["id"]

    assert {:ok, around} =
             Avcs.Turns.list_item_page(project, thread["id"], %{
               "limit" => 3,
               "around" => %{"turn_id" => anchor_turn_id}
             })

    assert Enum.map(around.items, & &1["content"]) == ["Turn 2", "Turn 3", "Turn 4"]
    assert around.page.anchor_turn_id == anchor_turn_id
    assert around.page.has_more_before == true
    assert around.page.has_more_after == true
    assert around.page.at_latest == false
  end

  test "thread defaults and turn overrides persist model and sandbox settings", %{
    project: project
  } do
    assert {:ok, thread} = Avcs.Threads.create_thread(project, "Model settings")
    assert thread["default_model"] == "gpt-5.5"
    assert thread["default_effort"] == "medium"

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

  test "new threads inherit global agent defaults", %{project: project} do
    setting_keys = [
      "agent.default_model",
      "agent.default_effort",
      "agent.default_approval_policy",
      "agent.default_sandbox_mode"
    ]

    on_exit(fn -> Avcs.SiteSettings.reset_settings(setting_keys) end)

    assert {:ok, _settings} =
             Avcs.SiteSettings.update_settings(%{
               "agent.default_model" => "gpt-5.1",
               "agent.default_effort" => "medium",
               "agent.default_approval_policy" => "on-request",
               "agent.default_sandbox_mode" => "read-only"
             })

    assert {:ok, thread} = Avcs.Threads.create_thread(project, "Global defaults")
    assert thread["default_model"] == "gpt-5.1"
    assert thread["default_effort"] == "medium"
    assert thread["default_approval_policy"] == "on-request"
    assert thread["default_sandbox_mode"] == "read-only"
  end

  test "trace events keep codex item lifecycle when item snapshot is overwritten", %{
    project: project
  } do
    assert {:ok, thread} = Avcs.Threads.create_thread(project, "Trace lifecycle")
    assert {:ok, created} = Avcs.Turns.create_user_turn(project, thread["id"], "Run tool", [])

    assert {:ok, running_item} =
             Avcs.Turns.upsert_codex_item(project,
               turn_id: created["turn"]["id"],
               thread_id: thread["id"],
               codex_item_id: "tool-1",
               type: "tool_call",
               role: "tool",
               content: "echo start",
               status: "running",
               payload: %{codex_item: %{"id" => "tool-1", "status" => "running"}}
             )

    assert {:ok, completed_item} =
             Avcs.Turns.upsert_codex_item(project,
               turn_id: created["turn"]["id"],
               thread_id: thread["id"],
               codex_item_id: "tool-1",
               type: "tool_result",
               role: "tool",
               content: "echo done",
               status: "completed",
               payload: %{codex_item: %{"id" => "tool-1", "status" => "completed"}}
             )

    assert running_item["id"] == completed_item["id"]

    {:ok, items} = Avcs.Turns.list_items(project, thread["id"])

    assert [%{"type" => "tool_result", "status" => "completed"}] =
             Enum.filter(items, &(&1["codex_item_id"] == "tool-1"))

    assert {:ok, events} = Avcs.Trace.list_events(project, thread["id"])
    tool_events = Enum.filter(events, &(&1["codex_item_id"] == "tool-1"))

    assert Enum.any?(
             tool_events,
             &(&1["event_name"] == "item_created" and &1["status"] == "running")
           )

    assert Enum.any?(
             tool_events,
             &(&1["event_name"] == "item_updated" and &1["status"] == "completed")
           )
  end

  test "trace events omit large base64 fields and keep a compact trace", %{project: project} do
    assert {:ok, thread} = Avcs.Threads.create_thread(project, "Trace sanitizer")
    large_result = String.duplicate("A", 120_000)

    assert {:ok, _event} =
             Avcs.Trace.append_event(project, %{
               scope: "item",
               event_name: "item_completed",
               thread_id: thread["id"],
               codex_item_id: "image-1",
               status: "completed",
               payload: %{"item" => %{"type" => "imageGeneration", "result" => large_result}},
               raw: %{
                 "method" => "item/completed",
                 "params" => %{"item" => %{"id" => "image-1", "result" => large_result}}
               }
             })

    assert {:ok, events} = Avcs.Trace.list_events(project, thread["id"])
    event = Enum.find(events, &(&1["codex_item_id"] == "image-1"))

    assert get_in(event, ["payload", "item", "result", "omitted"]) == true
    assert get_in(event, ["raw", "params", "item", "result", "omitted"]) == true
    assert get_in(event, ["payload", "item", "result", "size_bytes"]) == byte_size(large_result)
    assert Enum.any?(event["omitted"], &(&1["path"] == "payload.item.result"))
    assert Enum.any?(event["omitted"], &(&1["path"] == "raw.params.item.result"))

    encoded = Jason.encode!(event)
    refute String.contains?(encoded, String.slice(large_result, 0, 2_000))
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

  defp set_turn_time(project, turn_id, index) do
    timestamp = "2026-06-03T10:00:#{String.pad_leading(to_string(index), 2, "0")}Z"

    assert {:ok, :ok} =
             Avcs.Storage.SQLite.with_db(Avcs.Projects.project_db_path(project), fn db ->
               Avcs.Storage.SQLite.run!(
                 db,
                 "UPDATE turns SET created_at = ?, updated_at = ? WHERE id = ?",
                 [timestamp, timestamp, turn_id]
               )

               Avcs.Storage.SQLite.run!(
                 db,
                 "UPDATE items SET created_at = ?, updated_at = ? WHERE turn_id = ?",
                 [timestamp, timestamp, turn_id]
               )

               :ok
             end)

    timestamp
  end
end
