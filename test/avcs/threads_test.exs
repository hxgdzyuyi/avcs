defmodule Avcs.ThreadsTest do
  use ExUnit.Case, async: false

  alias Avcs.Storage.SQLite

  setup do
    previous_db_path = Application.get_env(:avcs, :global_db_path)

    test_dir =
      Path.join(System.tmp_dir!(), "avcs-threads-test-#{System.unique_integer([:positive])}")

    global_db_path = Path.join(test_dir, "global.sqlite3")
    project_dir = Path.join(test_dir, "project")

    File.rm_rf!(test_dir)
    Application.put_env(:avcs, :global_db_path, global_db_path)

    {:ok, project} = Avcs.Projects.open_project(project_dir)

    on_exit(fn ->
      if previous_db_path do
        Application.put_env(:avcs, :global_db_path, previous_db_path)
      else
        Application.delete_env(:avcs, :global_db_path)
      end

      File.rm_rf!(test_dir)
    end)

    %{project: project}
  end

  test "new threads are inserted at the top through sidebar order", %{project: project} do
    {:ok, first} = Avcs.Threads.create_thread(project, "First thread")
    {:ok, second} = Avcs.Threads.create_thread(project, "Second thread")

    assert second["sidebar_order"] < first["sidebar_order"]

    assert {:ok, threads} = Avcs.Threads.list_threads(project)
    assert Enum.map(threads, & &1["id"]) == [second["id"], first["id"]]
  end

  test "reorder threads persists sidebar order and ignores later created time", %{
    project: project
  } do
    {:ok, first} = Avcs.Threads.create_thread(project, "First thread")
    {:ok, second} = Avcs.Threads.create_thread(project, "Second thread")
    {:ok, third} = Avcs.Threads.create_thread(project, "Third thread")

    assert {:ok, threads} = Avcs.Threads.list_threads(project)
    assert Enum.map(threads, & &1["id"]) == [third["id"], second["id"], first["id"]]

    ordered_ids = [first["id"], third["id"], second["id"]]
    assert {:ok, reordered} = Avcs.Threads.reorder_threads(project, ordered_ids)
    assert Enum.map(reordered, & &1["id"]) == ordered_ids

    set_thread_time(project, second["id"], "2026-01-04T00:00:00Z")
    set_thread_time(project, third["id"], "2026-01-03T00:00:00Z")
    set_thread_time(project, first["id"], "2026-01-01T00:00:00Z")

    assert {:ok, after_activity} = Avcs.Threads.list_threads(project)
    assert Enum.map(after_activity, & &1["id"]) == ordered_ids
  end

  test "reorder threads rejects invalid payloads and archived ids", %{project: project} do
    {:ok, first} = Avcs.Threads.create_thread(project, "First thread")
    {:ok, second} = Avcs.Threads.create_thread(project, "Second thread")

    assert {:error, :invalid_reorder_payload} = Avcs.Threads.reorder_threads(project, [])

    assert {:error, :invalid_reorder_payload} =
             Avcs.Threads.reorder_threads(project, [first["id"]])

    assert {:error, :invalid_reorder_payload} =
             Avcs.Threads.reorder_threads(project, [first["id"], first["id"]])

    assert {:error, :thread_not_found} =
             Avcs.Threads.reorder_threads(project, [first["id"], Ecto.UUID.generate()])

    assert {:ok, :ok} = Avcs.Threads.archive_thread(project, second["id"])
    assert {:error, :thread_not_found} = Avcs.Threads.reorder_threads(project, [second["id"]])
  end

  defp set_thread_time(project, thread_id, timestamp) do
    SQLite.with_db!(Avcs.Projects.project_db_path(project), fn db ->
      SQLite.run!(
        db,
        "UPDATE threads SET created_at = ?, updated_at = ? WHERE id = ?",
        [timestamp, timestamp, thread_id]
      )
    end)
  end
end
