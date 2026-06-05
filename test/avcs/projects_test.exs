defmodule Avcs.ProjectsTest do
  use ExUnit.Case, async: false

  alias Avcs.Storage.SQLite

  setup do
    previous_db_path = Application.get_env(:avcs, :global_db_path)
    previous_blank_projects_dir = Application.get_env(:avcs, :blank_projects_dir)

    test_dir =
      Path.join(System.tmp_dir!(), "avcs-projects-test-#{System.unique_integer([:positive])}")

    global_db_path = Path.join(test_dir, "global.sqlite3")
    projects_dir = Path.join(test_dir, "projects")

    File.rm_rf!(test_dir)
    Application.put_env(:avcs, :global_db_path, global_db_path)
    Application.delete_env(:avcs, :blank_projects_dir)

    on_exit(fn ->
      if previous_db_path do
        Application.put_env(:avcs, :global_db_path, previous_db_path)
      else
        Application.delete_env(:avcs, :global_db_path)
      end

      if previous_blank_projects_dir do
        Application.put_env(:avcs, :blank_projects_dir, previous_blank_projects_dir)
      else
        Application.delete_env(:avcs, :blank_projects_dir)
      end

      File.rm_rf!(test_dir)
    end)

    %{global_db_path: global_db_path, projects_dir: projects_dir}
  end

  test "selecting an existing project does not update last opened time or reorder the list", %{
    global_db_path: global_db_path,
    projects_dir: projects_dir
  } do
    {:ok, older} = Avcs.Projects.open_project(Path.join(projects_dir, "older"))
    {:ok, newer} = Avcs.Projects.open_project(Path.join(projects_dir, "newer"))
    {:ok, _older_thread} = Avcs.Threads.create_thread(older, "Older work")
    {:ok, _newer_thread} = Avcs.Threads.create_thread(newer, "Newer work")

    set_project_times(global_db_path, older, "2026-01-01T00:00:00Z")
    set_project_times(global_db_path, newer, "2026-01-02T00:00:00Z")

    assert {:ok, before_select} = Avcs.Projects.list_projects()
    assert Enum.map(before_select, & &1["id"]) == [newer["id"], older["id"]]

    older_before = project_by_id(before_select, older["id"])

    assert {:ok, selected} = Avcs.Projects.select_project(older["id"])
    assert selected["id"] == older["id"]
    assert selected["last_opened_at"] == older_before["last_opened_at"]

    assert {:ok, after_select} = Avcs.Projects.list_projects()
    assert Enum.map(after_select, & &1["id"]) == [newer["id"], older["id"]]

    assert project_by_id(after_select, older["id"])["last_opened_at"] ==
             older_before["last_opened_at"]
  end

  test "list projects keeps sidebar order while exposing real project activity", %{
    global_db_path: global_db_path,
    projects_dir: projects_dir
  } do
    {:ok, first} = Avcs.Projects.open_project(Path.join(projects_dir, "first"))
    {:ok, second} = Avcs.Projects.open_project(Path.join(projects_dir, "second"))
    {:ok, _first_thread} = Avcs.Threads.create_thread(first, "First work")
    {:ok, _second_thread} = Avcs.Threads.create_thread(second, "Second work")

    set_project_times(global_db_path, first, "2026-01-03T00:00:00Z")
    set_project_times(global_db_path, second, "2026-01-01T00:00:00Z")

    assert {:ok, projects} = Avcs.Projects.list_projects()
    assert Enum.map(projects, & &1["id"]) == [second["id"], first["id"]]
    assert project_by_id(projects, first["id"])["last_activity_at"] == "2026-01-03T00:00:00Z"
  end

  test "project reorder persists sidebar order and ignores later activity", %{
    global_db_path: global_db_path,
    projects_dir: projects_dir
  } do
    {:ok, first} = Avcs.Projects.open_project(Path.join(projects_dir, "first"))
    {:ok, second} = Avcs.Projects.open_project(Path.join(projects_dir, "second"))
    {:ok, third} = Avcs.Projects.open_project(Path.join(projects_dir, "third"))

    assert {:ok, projects} = Avcs.Projects.list_projects()
    assert Enum.map(projects, & &1["id"]) == [third["id"], second["id"], first["id"]]

    assert {:ok, reordered} =
             Avcs.Projects.reorder_projects([first["id"], third["id"], second["id"]])

    assert Enum.map(reordered, & &1["id"]) == [first["id"], third["id"], second["id"]]

    set_project_times(global_db_path, second, "2026-01-04T00:00:00Z")

    assert {:ok, after_activity} = Avcs.Projects.list_projects()
    assert Enum.map(after_activity, & &1["id"]) == [first["id"], third["id"], second["id"]]

    assert {:ok, selected} = Avcs.Projects.select_project(third["id"])
    assert selected["id"] == third["id"]

    assert {:ok, after_select} = Avcs.Projects.list_projects()
    assert Enum.map(after_select, & &1["id"]) == [first["id"], third["id"], second["id"]]
  end

  test "project reorder rejects invalid payloads and archived ids", %{
    projects_dir: projects_dir
  } do
    {:ok, first} = Avcs.Projects.open_project(Path.join(projects_dir, "first"))
    {:ok, second} = Avcs.Projects.open_project(Path.join(projects_dir, "second"))

    assert {:error, :invalid_reorder_payload} = Avcs.Projects.reorder_projects([])
    assert {:error, :invalid_reorder_payload} = Avcs.Projects.reorder_projects([first["id"]])

    assert {:error, :invalid_reorder_payload} =
             Avcs.Projects.reorder_projects([first["id"], first["id"]])

    assert {:error, :project_not_found} =
             Avcs.Projects.reorder_projects([first["id"], Ecto.UUID.generate()])

    assert {:ok, _archived} = Avcs.Projects.archive_project(second["id"])

    assert {:error, :invalid_reorder_payload} =
             Avcs.Projects.reorder_projects([first["id"], second["id"]])
  end

  test "renaming a project updates only the global display name and survives reopen", %{
    projects_dir: projects_dir
  } do
    {:ok, project} = Avcs.Projects.open_project(Path.join(projects_dir, "original-folder"))
    {:ok, projects_before} = Avcs.Projects.list_projects()
    before_rename = project_by_id(projects_before, project["id"])

    assert {:ok, renamed} = Avcs.Projects.rename_project(project["id"], "  Renamed Project  ")
    assert renamed["name"] == "Renamed Project"
    assert renamed["folder_path"] == before_rename["folder_path"]
    assert renamed["project_db_path"] == before_rename["project_db_path"]
    assert renamed["sidebar_order"] == before_rename["sidebar_order"]
    assert renamed["last_opened_at"] == before_rename["last_opened_at"]
    assert Avcs.Projects.current_project()["name"] == "Renamed Project"

    assert {:ok, reopened} = Avcs.Projects.open_project(project["folder_path"])
    assert reopened["name"] == "Renamed Project"

    assert {:ok, projects_after} = Avcs.Projects.list_projects()
    assert project_by_id(projects_after, project["id"])["name"] == "Renamed Project"
  end

  test "project rename rejects invalid names and missing projects", %{projects_dir: projects_dir} do
    {:ok, project} = Avcs.Projects.open_project(Path.join(projects_dir, "rename-invalid"))

    for invalid_name <- ["", "  ", ".", "..", "bad/name", "bad\\name", nil] do
      assert {:error, :invalid_project_name} =
               Avcs.Projects.rename_project(project["id"], invalid_name)
    end

    assert {:error, :project_not_found} =
             Avcs.Projects.rename_project(Ecto.UUID.generate(), "Missing Project")
  end

  test "opening and selecting a project allows an empty thread list", %{
    projects_dir: projects_dir
  } do
    {:ok, project} = Avcs.Projects.open_project(Path.join(projects_dir, "empty"))

    assert project["current_thread_id"] == nil
    assert {:ok, []} = Avcs.Threads.list_threads(project)

    assert {:ok, selected} = Avcs.Projects.select_project(project["id"])
    assert selected["current_thread_id"] == nil
  end

  test "site settings persist registered global defaults and reject arbitrary keys", %{
    global_db_path: global_db_path
  } do
    assert {:ok, "gpt-5.5"} = Avcs.SiteSettings.get_setting("agent.default_model")
    assert {:ok, "medium"} = Avcs.SiteSettings.get_setting("agent.default_effort")
    assert {:ok, "en"} = Avcs.SiteSettings.get_setting("ui.locale")

    assert {:ok, data} =
             Avcs.SiteSettings.update_settings(%{
               "image.default_ratio" => "16:9",
               "image.default_count" => 3,
               "projects.default_root" => "~/Desktop/Avcs",
               "assets.scan_on_open" => true,
               "ui.locale" => "zh-hans"
             })

    assert data.settings["image.default_ratio"] == "16:9"
    assert data.settings["image.default_count"] == 3
    assert data.settings["projects.default_root"] == Path.expand("~/Desktop/Avcs")
    assert data.settings["assets.scan_on_open"] == true
    assert data.settings["ui.locale"] == "zh-hans"

    assert item = Enum.find(data.items, &(&1.key == "image.default_ratio"))
    assert item.is_default == false
    assert item.default_value == "auto"

    assert {:ok, "16:9"} = Avcs.SiteSettings.get_setting("image.default_ratio")

    assert {:error, {:unknown_site_setting, "turns.default_model"}} =
             Avcs.SiteSettings.update_settings(%{"turns.default_model" => "gpt-5"})

    assert {:error, {:invalid_site_setting, "image.default_count"}} =
             Avcs.SiteSettings.update_settings(%{"image.default_count" => 5})

    assert {:error, {:invalid_site_setting, "ui.locale"}} =
             Avcs.SiteSettings.update_settings(%{"ui.locale" => "fr"})

    assert {:ok, reset} = Avcs.SiteSettings.reset_setting("image.default_ratio")
    assert reset.settings["image.default_ratio"] == "auto"

    assert {:ok, reset_locale} = Avcs.SiteSettings.reset_setting("ui.locale")
    assert reset_locale.settings["ui.locale"] == "en"

    SQLite.with_db!(global_db_path, fn db ->
      refute SQLite.one!(db, "SELECT * FROM app_settings WHERE key = ?", [
               "image.default_ratio"
             ])

      assert SQLite.one!(db, "SELECT * FROM app_settings WHERE key = ?", [
               "image.default_count"
             ])
    end)
  end

  test "blank projects use global default root when no application override is set", %{
    projects_dir: projects_dir
  } do
    root = Path.join(projects_dir, "configured-root")

    assert {:ok, _settings} =
             Avcs.SiteSettings.update_settings(%{"projects.default_root" => root})

    assert {:ok, project} = Avcs.Projects.create_blank_project("Global Root")
    assert project["folder_path"] == Path.join(root, "Global Root")
    assert File.exists?(Path.join([project["folder_path"], ".avcs", "project.sqlite3"]))
  end

  test "project sqlite info reports file stats, pragmas, and table row counts", %{
    projects_dir: projects_dir
  } do
    {:ok, project} = Avcs.Projects.open_project(Path.join(projects_dir, "sqlite-info"))
    {:ok, _thread} = Avcs.Threads.create_thread(project, "SQLite info")

    assert {:ok, info} = Avcs.Projects.project_sqlite_info(project)
    assert info.project_id == project["id"]
    assert info.db_path == Avcs.Projects.project_db_path(project)
    assert info.exists == true
    assert info.status == "available"
    assert info.size_bytes > 0
    assert info.file_mtime
    assert info.sqlite_info.page_size > 0
    assert info.sqlite_info.journal_mode in ["wal", "delete", "memory", "off"]
    assert info.sqlite_info.schema_version == "5"

    assert %{rows: rows} = Enum.find(info.table_rows, &(&1.name == "threads"))
    assert rows >= 1
  end

  test "project sqlite fast maintenance records optimized timestamp", %{
    projects_dir: projects_dir
  } do
    {:ok, project} = Avcs.Projects.open_project(Path.join(projects_dir, "sqlite-maintenance"))

    assert {:ok, result} =
             Avcs.Projects.project_sqlite_maintenance(project, "fast_optimize", async: false)

    assert result.status == "completed"
    assert result.job_id

    assert {:ok, info} = Avcs.Projects.project_sqlite_info(project)
    assert info.optimized_at
  end

  defp set_project_times(global_db_path, project, timestamp) do
    SQLite.with_db!(global_db_path, fn db ->
      SQLite.run!(
        db,
        "UPDATE projects SET updated_at = ?, last_opened_at = ? WHERE id = ?",
        [timestamp, timestamp, project["id"]]
      )
    end)

    set_thread_activity(project, timestamp)
  end

  defp set_thread_activity(project, timestamp) do
    SQLite.with_db!(Avcs.Projects.project_db_path(project), fn db ->
      SQLite.run!(
        db,
        "UPDATE threads SET created_at = ?, updated_at = ? WHERE archived_at IS NULL",
        [timestamp, timestamp]
      )
    end)
  end

  defp project_by_id(projects, id) do
    Enum.find(projects, &(&1["id"] == id))
  end
end
