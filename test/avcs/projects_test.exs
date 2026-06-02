defmodule Avcs.ProjectsTest do
  use ExUnit.Case, async: false

  alias Avcs.Storage.SQLite

  setup do
    previous_db_path = Application.get_env(:avcs, :global_db_path)

    test_dir =
      Path.join(System.tmp_dir!(), "avcs-projects-test-#{System.unique_integer([:positive])}")

    global_db_path = Path.join(test_dir, "global.sqlite3")
    projects_dir = Path.join(test_dir, "projects")

    File.rm_rf!(test_dir)
    Application.put_env(:avcs, :global_db_path, global_db_path)

    on_exit(fn ->
      if previous_db_path do
        Application.put_env(:avcs, :global_db_path, previous_db_path)
      else
        Application.delete_env(:avcs, :global_db_path)
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

  test "list projects sorts by real project activity before last opened time", %{
    global_db_path: global_db_path,
    projects_dir: projects_dir
  } do
    {:ok, quiet} = Avcs.Projects.open_project(Path.join(projects_dir, "quiet"))
    {:ok, active} = Avcs.Projects.open_project(Path.join(projects_dir, "active"))
    {:ok, _quiet_thread} = Avcs.Threads.create_thread(quiet, "Quiet work")
    {:ok, _active_thread} = Avcs.Threads.create_thread(active, "Active work")

    set_project_times(global_db_path, quiet, "2026-01-02T00:00:00Z")
    set_project_times(global_db_path, active, "2026-01-01T00:00:00Z")
    set_thread_activity(active, "2026-01-03T00:00:00Z")

    assert {:ok, projects} = Avcs.Projects.list_projects()
    assert Enum.map(projects, & &1["id"]) == [active["id"], quiet["id"]]
    assert project_by_id(projects, active["id"])["last_activity_at"] == "2026-01-03T00:00:00Z"
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
