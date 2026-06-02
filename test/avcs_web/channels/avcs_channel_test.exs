defmodule AvcsWeb.AvcsChannelTest do
  use ExUnit.Case, async: false

  import Phoenix.ChannelTest

  @endpoint AvcsWeb.Endpoint

  defmodule NoopRunner do
    def start(_project, _thread_id, _turn_id, _text, _asset_ids) do
      Task.start(fn -> :ok end)
    end

    def respond_approval(_thread_id, _turn_id, _payload), do: :ok
  end

  setup do
    previous_runner = Application.get_env(:avcs, :agent_runner)
    Application.put_env(:avcs, :agent_runner, NoopRunner)

    project_dir =
      Path.join(System.tmp_dir!(), "avcs-channel-#{System.unique_integer([:positive])}")

    File.rm_rf!(project_dir)
    {:ok, project} = Avcs.Projects.open_project(project_dir)

    on_exit(fn ->
      if previous_runner do
        Application.put_env(:avcs, :agent_runner, previous_runner)
      else
        Application.delete_env(:avcs, :agent_runner)
      end

      File.rm_rf!(project_dir)
    end)

    {:ok, socket} = connect(AvcsWeb.UserSocket, %{})
    {:ok, join_reply, socket} = subscribe_and_join(socket, AvcsWeb.AvcsChannel, "avcs:lobby", %{})

    %{project: project, socket: socket, join_reply: join_reply}
  end

  test "joins with current project and manages threads through websocket events", %{
    project: project,
    socket: socket,
    join_reply: join_reply
  } do
    assert join_reply.project["id"] == project["id"]
    assert Enum.any?(join_reply.projects, &(&1["id"] == project["id"]))

    create_ref = push(socket, "thread:create", %{"title" => "Visual ideas"})
    assert_reply create_ref, :ok, %{success: true, data: thread}
    assert thread["title"] == "Visual ideas"

    rename_ref = push(socket, "thread:rename", %{"id" => thread["id"], "title" => "Logo ideas"})
    assert_reply rename_ref, :ok, %{success: true, data: renamed}
    assert renamed["title"] == "Logo ideas"

    select_ref = push(socket, "thread:select", %{"id" => thread["id"]})
    assert_reply select_ref, :ok, %{success: true, data: %{current_thread_id: selected_id}}
    assert selected_id == thread["id"]

    list_ref = push(socket, "threads:list", %{})
    assert_reply list_ref, :ok, %{success: true, data: %{items: threads}}
    assert Enum.any?(threads, &(&1["id"] == thread["id"]))
  end

  test "message send titles an untitled thread from user text", %{
    project: project,
    socket: socket
  } do
    {:ok, thread} = Avcs.Threads.create_thread(project, "Untitled thread")

    send_ref =
      push(socket, "message:send", %{
        "thread_id" => thread["id"],
        "text" => "  Generate a Xiaohongshu cover\nwith bold type  "
      })

    assert_reply send_ref, :ok, %{success: true, data: data}
    assert data["thread"]["title"] == "Generate a Xiaohongshu cover with bold type"

    {:ok, updated} = Avcs.Threads.get_thread(project, thread["id"])
    assert updated["title"] == "Generate a Xiaohongshu cover with bold type"
  end

  test "archives the last thread without recreating a default thread", %{
    socket: socket
  } do
    create_ref = push(socket, "thread:create", %{"title" => "Only thread"})
    assert_reply create_ref, :ok, %{success: true, data: thread}

    delete_ref = push(socket, "thread:delete", %{"id" => thread["id"]})
    assert_reply delete_ref, :ok, %{success: true, data: %{current_thread_id: nil}}

    assert Avcs.Session.current_thread_id() == nil

    list_ref = push(socket, "threads:list", %{})
    assert_reply list_ref, :ok, %{success: true, data: %{items: []}}
  end

  test "lists indexed projects and selects a project through websocket events", %{
    project: project,
    socket: socket
  } do
    other_dir =
      Path.join(System.tmp_dir!(), "avcs-channel-other-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(other_dir) end)

    {:ok, other_project} = Avcs.Projects.open_project(other_dir)
    {:ok, other_thread} = Avcs.Threads.create_thread(other_project, "Other project thread")

    list_ref = push(socket, "projects:list", %{})
    assert_reply list_ref, :ok, %{success: true, data: %{items: projects}}
    assert Enum.any?(projects, &(&1["id"] == project["id"]))
    assert Enum.any?(projects, &(&1["id"] == other_project["id"]))

    threads_ref = push(socket, "threads:list", %{"project_id" => other_project["id"]})
    assert_reply threads_ref, :ok, %{success: true, data: %{items: threads}}
    assert Enum.any?(threads, &(&1["id"] == other_thread["id"]))

    select_ref = push(socket, "project:select", %{"id" => project["id"]})
    assert_reply select_ref, :ok, %{success: true, data: %{project: selected}}
    assert selected["id"] == project["id"]
    assert selected["current_thread_id"] == nil
  end

  test "archives and deletes project references through websocket events", %{
    project: project,
    socket: socket
  } do
    archived_dir =
      Path.join(System.tmp_dir!(), "avcs-channel-archive-#{System.unique_integer([:positive])}")

    deleted_dir =
      Path.join(System.tmp_dir!(), "avcs-channel-delete-#{System.unique_integer([:positive])}")

    on_exit(fn ->
      File.rm_rf!(archived_dir)
      File.rm_rf!(deleted_dir)
    end)

    {:ok, archived_project} = Avcs.Projects.open_project(archived_dir)
    {:ok, deleted_project} = Avcs.Projects.open_project(deleted_dir)

    archive_ref = push(socket, "project:archive", %{"id" => archived_project["id"]})

    assert_reply archive_ref, :ok, %{
      success: true,
      data: %{archived_project_id: archived_project_id}
    }

    assert archived_project_id == archived_project["id"]
    assert File.dir?(archived_dir)

    delete_ref = push(socket, "project:delete", %{"id" => deleted_project["id"]})

    assert_reply delete_ref, :ok, %{
      success: true,
      data: %{deleted_project_id: deleted_project_id}
    }

    assert deleted_project_id == deleted_project["id"]
    assert File.dir?(deleted_dir)

    list_ref = push(socket, "projects:list", %{})
    assert_reply list_ref, :ok, %{success: true, data: %{items: projects}}
    refute Enum.any?(projects, &(&1["id"] == archived_project["id"]))
    refute Enum.any?(projects, &(&1["id"] == deleted_project["id"]))
    assert Enum.any?(projects, &(&1["id"] == project["id"]))
  end

  test "message:send persists the user turn and image reference payload", %{
    project: project,
    socket: socket
  } do
    {:ok, thread} = Avcs.Threads.ensure_default(project)
    image_path = Path.join([project["folder_path"], "work", "reference.png"])
    File.write!(image_path, test_png())
    {:ok, asset} = Avcs.Assets.upsert_asset(project, image_path, source: "scan")

    ref =
      push(socket, "message:send", %{
        "thread_id" => thread["id"],
        "text" => "Use the reference",
        "asset_ids" => [asset["id"]]
      })

    assert_reply ref, :ok, %{success: true, data: %{"item" => item}}
    assert item["type"] == "user_message"
    assert item["payload"]["asset_ids"] == [asset["id"]]

    {:ok, items} = Avcs.Turns.list_items(project, thread["id"])
    assert Enum.any?(items, &(&1["content"] == "Use the reference"))
  end

  test "approval:respond persists the user decision", %{project: project, socket: socket} do
    {:ok, thread} = Avcs.Threads.ensure_default(project)
    {:ok, created} = Avcs.Turns.create_user_turn(project, thread["id"], "Run command", [])

    event = %{
      "threadId" => "codex-thread-1",
      "turnId" => "codex-turn-1",
      "reviewId" => "review-1",
      "startedAtMs" => 1_700_000_000_100,
      "action" => %{
        "type" => "command",
        "command" => "echo render",
        "cwd" => project["folder_path"],
        "source" => "shell"
      },
      "review" => %{"status" => "inProgress"}
    }

    {:ok, approval_item} =
      Avcs.Turns.upsert_codex_item(
        project,
        Avcs.Agent.ApprovalReview.started_item_attrs(
          thread["id"],
          created["turn"]["id"],
          event,
          %{"method" => "item/autoApprovalReview/started", "params" => event}
        )
      )

    ref =
      push(socket, "approval:respond", %{
        "thread_id" => thread["id"],
        "turn_id" => created["turn"]["id"],
        "review_id" => approval_item["payload"]["review_id"],
        "decision" => "approve"
      })

    assert_reply ref, :ok, %{success: true, data: %{item: updated}}
    assert updated["status"] == "approved"
    assert updated["payload"]["user_decision"] == "approve"
    assert updated["payload"]["event"]["reviewId"] == "review-1"
  end

  defp test_png do
    Base.decode64!(
      "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII="
    )
  end
end
