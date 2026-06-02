defmodule AvcsWeb.ProjectControllerTest do
  use AvcsWeb.ConnCase

  test "creates a blank project under the configured blank project root", %{conn: conn} do
    root =
      Path.join(System.tmp_dir!(), "avcs-controller-blank-#{System.unique_integer([:positive])}")

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

    conn =
      post(conn, ~p"/api/project/create_blank", %{
        "name" => "Mood Board"
      })

    assert %{"success" => true, "data" => project} = json_response(conn, 200)
    assert project["name"] == "Mood Board"
    assert project["folder_path"] == Path.join(root, "Mood Board")
    assert File.dir?(Path.join(project["folder_path"], "work"))
    assert File.dir?(Path.join(project["folder_path"], "output"))
    assert File.exists?(Path.join([project["folder_path"], ".avcs", "project.sqlite3"]))
  end

  test "opens and initializes a local project folder", %{conn: conn} do
    project_dir =
      Path.join(System.tmp_dir!(), "avcs-project-#{System.unique_integer([:positive])}")

    conn =
      post(conn, ~p"/api/project/open", %{
        "path" => project_dir
      })

    assert %{"success" => true, "data" => project} = json_response(conn, 200)
    assert project["folder_path"] == project_dir
    assert File.dir?(Path.join(project_dir, "work"))
    assert File.dir?(Path.join(project_dir, "output"))
    assert File.exists?(Path.join([project_dir, ".avcs", "project.sqlite3"]))
    assert File.exists?(Application.fetch_env!(:avcs, :global_db_path))
  end
end
