defmodule AvcsWeb.AvcsChannelTest do
  use ExUnit.Case, async: false

  import Phoenix.ChannelTest

  @endpoint AvcsWeb.Endpoint

  defmodule NoopRunner do
    def submit(project, thread_id, text, asset_ids, turn_settings) do
      Avcs.Turns.create_user_turn(project, thread_id, text, asset_ids, turn_settings)
    end

    def start(_project, _thread_id, _turn_id, _text, _asset_ids) do
      Task.start(fn -> :ok end)
    end

    def respond_approval(_thread_id, _turn_id, _payload), do: :ok
  end

  defmodule StopRunner do
    def stop(_project, thread_id, turn_id) do
      send(Application.fetch_env!(:avcs, :channel_test_pid), {:stop_turn, thread_id, turn_id})
      {:ok, %{turn_id: turn_id, status: "stopping"}}
    end
  end

  defmodule EditRerunRunner do
    def rerun_from_item(project, item_id, content) do
      with {:ok, result} <-
             Avcs.Turns.edit_and_invalidate_after(project, item_id, content, status: "queued") do
        thread_id = result["turn"]["thread_id"]

        Avcs.Events.broadcast("item:updated", %{
          thread_id: thread_id,
          turn_id: result["turn"]["id"],
          item: result["item"]
        })

        {:ok, items} = Avcs.Turns.list_items(project, thread_id)
        Avcs.Events.broadcast("thread:items", %{thread_id: thread_id, items: items})

        Avcs.Events.broadcast("turn:started", %{
          thread_id: thread_id,
          turn_id: result["turn"]["id"],
          turn: result["turn"]
        })

        {:ok, result}
      end
    end
  end

  defmodule ActiveSteerClient do
    def active_turn(_project, _thread_id) do
      {:ok, %{turn_id: Application.fetch_env!(:avcs, :channel_active_turn_id), worker: self()}}
    end

    def steer_turn(_project, thread_id, text, reference_paths, _opts) do
      send(Application.fetch_env!(:avcs, :channel_test_pid), {
        :steer_turn,
        thread_id,
        text,
        reference_paths
      })

      {:ok, %{"turnId" => "codex-turn-1"}}
    end
  end

  defmodule QueuedPoolClient do
    def active_turn(_project, _thread_id), do: :none

    def steer_turn(_project, _thread_id, _text, _reference_paths, _opts) do
      {:error, :not_running}
    end

    def run_turn(
          _project,
          _thread_id,
          _turn_id,
          _codex_thread_id,
          _text,
          _reference_paths,
          _on_event,
          _settings
        ) do
      send(Application.fetch_env!(:avcs, :channel_test_pid), {:queued_run_started, self()})

      receive do
        :finish ->
          {:ok,
           %{
             codex_thread_id: "codex-thread-queued",
             codex_turn_id: "codex-turn-queued",
             assistant_text: "",
             items: [],
             thread_name: nil
           }}
      after
        1_000 ->
          {:error, "test timeout"}
      end
    end
  end

  defmodule BlockingModelsClient do
    def list_models do
      send(Application.fetch_env!(:avcs, :channel_test_pid), {:models_list_started, self()})

      receive do
        :finish_models ->
          {:ok, [%{"id" => "fake-model"}]}
      after
        1_000 ->
          {:error, "test timeout"}
      end
    end
  end

  setup do
    previous_runner = Application.get_env(:avcs, :agent_runner)
    previous_client = Application.get_env(:avcs, :codex_client)
    previous_test_pid = Application.get_env(:avcs, :channel_test_pid)
    previous_active_turn_id = Application.get_env(:avcs, :channel_active_turn_id)
    Application.put_env(:avcs, :agent_runner, NoopRunner)
    Application.put_env(:avcs, :channel_test_pid, self())
    Avcs.SiteSettings.reset_settings(Avcs.SiteSettings.keys())

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

      if previous_client do
        Application.put_env(:avcs, :codex_client, previous_client)
      else
        Application.delete_env(:avcs, :codex_client)
      end

      if previous_test_pid do
        Application.put_env(:avcs, :channel_test_pid, previous_test_pid)
      else
        Application.delete_env(:avcs, :channel_test_pid)
      end

      if previous_active_turn_id do
        Application.put_env(:avcs, :channel_active_turn_id, previous_active_turn_id)
      else
        Application.delete_env(:avcs, :channel_active_turn_id)
      end

      Avcs.SiteSettings.reset_settings(Avcs.SiteSettings.keys())
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

  test "site settings websocket events read, update, reset, and reject invalid settings", %{
    socket: socket
  } do
    get_ref = push(socket, "site_settings:get", %{})

    assert_reply get_ref, :ok, %{
      success: true,
      data: %{items: items, settings: settings}
    }

    assert settings["agent.default_approval_policy"] == "never"
    assert settings["agent.default_model"] == "gpt-5.5"
    assert settings["agent.default_effort"] == "medium"
    assert settings["ui.locale"] == "en"
    assert Enum.any?(items, &(&1.key == "projects.default_root"))
    assert Enum.any?(items, &(&1.key == "ui.locale"))

    update_ref =
      push(socket, "site_settings:update", %{
        "settings" => %{
          "agent.default_model" => "gpt-5",
          "image.default_ratio" => "9:16",
          "image.default_count" => 2,
          "image.transparent_background" => true,
          "ui.locale" => "zh-hans"
        }
      })

    assert_reply update_ref, :ok, %{
      success: true,
      data: %{settings: updated_settings}
    }

    assert updated_settings["agent.default_model"] == "gpt-5"
    assert updated_settings["image.default_ratio"] == "9:16"
    assert updated_settings["image.default_count"] == 2
    assert updated_settings["image.transparent_background"] == true
    assert updated_settings["ui.locale"] == "zh-hans"
    assert_push "site_settings:updated", %{settings: pushed_settings}
    assert pushed_settings["image.default_count"] == 2
    assert pushed_settings["ui.locale"] == "zh-hans"

    invalid_ref =
      push(socket, "site_settings:update", %{
        "settings" => %{"agent.default_effort" => "extreme"}
      })

    assert_reply invalid_ref, :ok, %{
      success: false,
      error: %{code: "invalid_site_setting", details: %{key: "agent.default_effort"}}
    }

    invalid_locale_ref =
      push(socket, "site_settings:update", %{
        "settings" => %{"ui.locale" => "fr"}
      })

    assert_reply invalid_locale_ref, :ok, %{
      success: false,
      error: %{code: "invalid_site_setting", details: %{key: "ui.locale"}}
    }

    unknown_ref =
      push(socket, "site_settings:update", %{
        "settings" => %{"unknown.key" => true}
      })

    assert_reply unknown_ref, :ok, %{
      success: false,
      error: %{code: "unknown_site_setting", details: %{key: "unknown.key"}}
    }

    reset_ref =
      push(socket, "site_settings:reset", %{"keys" => ["image.default_count", "ui.locale"]})

    assert_reply reset_ref, :ok, %{
      success: true,
      data: %{settings: reset_settings}
    }

    assert reset_settings["image.default_count"] == 1
    assert reset_settings["ui.locale"] == "en"
  end

  test "models list does not block later websocket requests", %{socket: socket} do
    Application.put_env(:avcs, :codex_client, BlockingModelsClient)

    models_ref = push(socket, "models:list", %{})
    assert_receive {:models_list_started, models_pid}

    create_ref = push(socket, "thread:create", %{"title" => "Selectable"})
    assert_reply create_ref, :ok, %{success: true, data: thread}

    select_ref = push(socket, "thread:select", %{"id" => thread["id"]})
    assert_reply select_ref, :ok, %{success: true, data: %{current_thread_id: selected_id}}
    assert selected_id == thread["id"]

    send(models_pid, :finish_models)
    assert_reply models_ref, :ok, %{success: true, data: %{items: [%{"id" => "fake-model"}]}}
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

  test "message send steers active turn without creating another turn", %{
    project: project,
    socket: socket
  } do
    Application.put_env(:avcs, :agent_runner, Avcs.Agent.Runner)
    Application.put_env(:avcs, :codex_client, ActiveSteerClient)

    {:ok, thread} = Avcs.Threads.create_thread(project, "Active thread")
    {:ok, created} = Avcs.Turns.create_user_turn(project, thread["id"], "Original", [])
    Application.put_env(:avcs, :channel_active_turn_id, created["turn"]["id"])

    send_ref =
      push(socket, "message:send", %{
        "thread_id" => thread["id"],
        "text" => "Add this while running"
      })

    assert_reply send_ref, :ok, %{success: true, data: data}
    assert data["steered"] == true
    assert data["turn"]["id"] == created["turn"]["id"]
    assert data["item"]["payload"]["steered"] == true

    thread_id = thread["id"]
    assert_receive {:steer_turn, ^thread_id, "Add this while running", []}

    {:ok, turns} = Avcs.Turns.list_turns(project, thread["id"])
    assert Enum.map(turns, & &1["id"]) == [created["turn"]["id"]]

    {:ok, items} = Avcs.Turns.list_items(project, thread["id"])
    assert Enum.count(items, &(&1["type"] == "user_message")) == 2
  end

  test "message send creates queued turn before pool worker assignment", %{
    project: project,
    socket: socket
  } do
    Application.put_env(:avcs, :agent_runner, Avcs.Agent.Runner)
    Application.put_env(:avcs, :codex_client, QueuedPoolClient)

    {:ok, thread} = Avcs.Threads.create_thread(project, "Queued thread")

    send_ref =
      push(socket, "message:send", %{
        "thread_id" => thread["id"],
        "text" => "Wait for a worker"
      })

    assert_reply send_ref, :ok, %{success: true, data: data}
    assert data["turn"]["status"] == "queued"

    assert_receive {:queued_run_started, runner_pid}

    {:ok, [turn]} = Avcs.Turns.list_turns(project, thread["id"])
    assert turn["status"] == "queued"

    runner_ref = Process.monitor(runner_pid)
    send(runner_pid, :finish)

    wait_until(fn ->
      case Avcs.Turns.list_turns(project, thread["id"]) do
        {:ok, [%{"status" => "completed"}]} -> true
        _other -> false
      end
    end)

    assert_receive {:DOWN, ^runner_ref, :process, ^runner_pid, _reason}
  end

  test "turn stop delegates to the agent runner", %{project: project, socket: socket} do
    Application.put_env(:avcs, :agent_runner, StopRunner)

    {:ok, thread} = Avcs.Threads.create_thread(project, "Stop thread")
    {:ok, created} = Avcs.Turns.create_user_turn(project, thread["id"], "Running", [])

    stop_ref =
      push(socket, "turn:stop", %{
        "thread_id" => thread["id"],
        "turn_id" => created["turn"]["id"]
      })

    assert_reply stop_ref, :ok, %{
      success: true,
      data: %{
        thread_id: thread_id,
        turn_id: turn_id,
        status: "stopping"
      }
    }

    assert thread_id == thread["id"]
    assert turn_id == created["turn"]["id"]
    assert_receive {:stop_turn, ^thread_id, ^turn_id}
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

  test "archives all threads for a project through websocket events", %{
    project: project,
    socket: socket
  } do
    {:ok, first} = Avcs.Threads.create_thread(project, "First thread")
    {:ok, second} = Avcs.Threads.create_thread(project, "Second thread")

    select_ref = push(socket, "thread:select", %{"id" => first["id"]})
    assert_reply select_ref, :ok, %{success: true, data: %{current_thread_id: selected_id}}
    assert selected_id == first["id"]

    archive_ref = push(socket, "threads:archive_all", %{"project_id" => project["id"]})

    assert_reply archive_ref, :ok, %{
      success: true,
      data: %{
        archived_count: 2,
        archived_thread_ids: archived_thread_ids,
        current_thread_id: nil,
        project_id: project_id
      }
    }

    assert project_id == project["id"]
    assert Enum.sort(archived_thread_ids) == Enum.sort([first["id"], second["id"]])
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

  test "renames the current project through websocket events", %{
    project: project,
    socket: socket
  } do
    rename_ref = push(socket, "project:rename", %{"id" => project["id"], "name" => "Renamed"})

    assert_reply rename_ref, :ok, %{success: true, data: renamed}
    assert renamed["id"] == project["id"]
    assert renamed["name"] == "Renamed"

    assert_push "project:updated", %{project: pushed_project}
    assert pushed_project["id"] == project["id"]
    assert pushed_project["name"] == "Renamed"

    assert_push "projects:updated", %{items: projects}
    assert Enum.any?(projects, &(&1["id"] == project["id"] and &1["name"] == "Renamed"))

    invalid_ref =
      push(socket, "project:rename", %{"id" => project["id"], "name" => "bad/name"})

    assert_reply invalid_ref, :ok, %{
      success: false,
      error: %{code: "invalid_project_name"}
    }
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
        "asset_ids" => [asset["id"]],
        "data_provider" => %{
          "slug" => "avcs-data-prodiver-apod",
          "name" => "NASA APOD",
          "version" => "0.1.0",
          "loaded" => true
        }
      })

    assert_reply ref, :ok, %{success: true, data: %{"item" => item}}
    assert item["type"] == "user_message"
    assert item["payload"]["asset_ids"] == [asset["id"]]
    assert item["payload"]["data_provider"]["slug"] == "avcs-data-prodiver-apod"

    {:ok, items} = Avcs.Turns.list_items(project, thread["id"])
    assert Enum.any?(items, &(&1["content"] == "Use the reference"))
    assert [persisted] = Enum.filter(items, &(&1["type"] == "user_message"))
    assert persisted["turn_data_provider"]["name"] == "NASA APOD"

    {:ok, [turn]} = Avcs.Turns.list_turns(project, thread["id"])
    assert turn["data_provider"]["slug"] == "avcs-data-prodiver-apod"
  end

  test "message:send rejects unloaded data provider payload", %{socket: socket} do
    ref =
      push(socket, "message:send", %{
        "text" => "Use APOD",
        "data_provider" => %{
          "slug" => "avcs-data-prodiver-apod",
          "name" => "NASA APOD",
          "loaded" => false
        }
      })

    assert_reply ref, :ok, %{
      success: false,
      error: %{code: "data_provider_not_loaded"}
    }
  end

  test "message:send validates and persists visual mask edit payload", %{
    project: project,
    socket: socket
  } do
    {:ok, thread} = Avcs.Threads.ensure_default(project)
    base_path = Path.join([project["folder_path"], "output", "base.png"])
    mask_path = Path.join([project["folder_path"], ".avcs", "cache", "temp", "masks", "mask.png"])
    File.mkdir_p!(Path.dirname(mask_path))
    File.write!(base_path, test_png())
    File.write!(mask_path, test_png_alt())
    {:ok, base_asset} = Avcs.Assets.upsert_asset(project, base_path, source: "generated")
    {:ok, mask_asset} = Avcs.Assets.upsert_asset(project, mask_path, source: "mask")

    ref =
      push(socket, "message:send", %{
        "thread_id" => thread["id"],
        "text" => "Replace the marked area",
        "asset_ids" => [base_asset["id"], mask_asset["id"]],
        "mask_edit" => %{
          "mode" => "visual_reference",
          "base_asset_id" => base_asset["id"],
          "mask_asset_id" => mask_asset["id"],
          "mask_semantics" => "white_edit_black_keep"
        }
      })

    assert_reply ref, :ok, %{success: true, data: %{"item" => item}}
    assert item["payload"]["asset_ids"] == [base_asset["id"], mask_asset["id"]]
    assert item["payload"]["mask_edit"]["mode"] == "visual_reference"
    assert item["payload"]["mask_edit"]["base_asset_id"] == base_asset["id"]
    assert item["payload"]["mask_edit"]["mask_asset_id"] == mask_asset["id"]
  end

  test "message:edit_rerun invalidates later path and broadcasts refreshed items", %{
    project: project,
    socket: socket
  } do
    Application.put_env(:avcs, :agent_runner, EditRerunRunner)

    {:ok, thread} = Avcs.Threads.create_thread(project, "Edit from history")

    {:ok, first} =
      Avcs.Turns.create_user_turn(project, thread["id"], "Original prompt", [])

    {:ok, _turn} = Avcs.Turns.complete_turn(project, first["turn"]["id"], "codex-turn-1")
    set_turn_time(project, first["turn"]["id"], 1)

    {:ok, second} =
      Avcs.Turns.create_user_turn(project, thread["id"], "Later prompt", [])

    {:ok, _turn} = Avcs.Turns.complete_turn(project, second["turn"]["id"], "codex-turn-2")
    set_turn_time(project, second["turn"]["id"], 2)

    ref =
      push(socket, "message:edit_rerun", %{
        "item_id" => first["item"]["id"],
        "content" => "Revised prompt"
      })

    assert_reply ref, :ok, %{success: true, data: data}
    assert data["item"]["content"] == "Revised prompt"
    assert data["turn"]["id"] == first["turn"]["id"]
    assert data["turn"]["status"] == "queued"
    assert data["invalidated_turn_ids"] == [second["turn"]["id"]]
    assert second["item"]["id"] in data["invalidated_item_ids"]

    assert_push "item:updated", %{item: pushed_item}
    assert pushed_item["id"] == first["item"]["id"]
    assert pushed_item["content"] == "Revised prompt"

    assert_push "thread:items", %{thread_id: pushed_thread_id, items: pushed_items}
    assert pushed_thread_id == thread["id"]
    assert Enum.map(pushed_items, & &1["content"]) == ["Revised prompt"]

    assert_push "turn:started", %{turn_id: pushed_turn_id, turn: pushed_turn}
    assert pushed_turn_id == first["turn"]["id"]
    assert pushed_turn["status"] == "queued"
  end

  test "thread:items:page returns turn windows and request ids", %{
    project: project,
    socket: socket
  } do
    {:ok, thread} = Avcs.Threads.create_thread(project, "Paged channel thread")

    for index <- 1..3 do
      {:ok, created} = Avcs.Turns.create_user_turn(project, thread["id"], "Channel #{index}", [])
      set_turn_time(project, created["turn"]["id"], index)
    end

    latest_ref =
      push(socket, "thread:items:page", %{
        "thread_id" => thread["id"],
        "limit" => 2,
        "request_id" => "req-latest"
      })

    assert_reply latest_ref, :ok, %{
      success: true,
      data: %{items: latest_items, page: latest_page, request_id: "req-latest"}
    }

    assert Enum.map(latest_items, & &1["content"]) == ["Channel 2", "Channel 3"]
    assert latest_page.mode == "latest"
    assert latest_page.has_more_before == true

    before_ref =
      push(socket, "thread:items:page", %{
        "thread_id" => thread["id"],
        "limit" => 2,
        "before" => latest_page.before_cursor,
        "request_id" => "req-before"
      })

    assert_reply before_ref, :ok, %{
      success: true,
      data: %{items: before_items, page: before_page, request_id: "req-before"}
    }

    assert Enum.map(before_items, & &1["content"]) == ["Channel 1"]
    assert before_page.has_more_before == false
    assert before_page.has_more_after == true
  end

  test "thread:items:page rejects conflicting cursors and missing anchors", %{
    project: project,
    socket: socket
  } do
    {:ok, thread} = Avcs.Threads.create_thread(project, "Invalid page thread")
    {:ok, created} = Avcs.Turns.create_user_turn(project, thread["id"], "One", [])
    set_turn_time(project, created["turn"]["id"], 1)

    cursor = %{created_at: "2026-06-03T10:00:01Z", id: created["turn"]["id"]}

    invalid_ref =
      push(socket, "thread:items:page", %{
        "thread_id" => thread["id"],
        "before" => cursor,
        "after" => cursor
      })

    assert_reply invalid_ref, :ok, %{
      success: false,
      error: %{code: "invalid_page_cursor"}
    }

    missing_anchor_ref =
      push(socket, "thread:items:page", %{
        "thread_id" => thread["id"],
        "around" => %{"turn_id" => Ecto.UUID.generate()}
      })

    assert_reply missing_anchor_ref, :ok, %{
      success: false,
      error: %{code: "turn_anchor_not_found"}
    }
  end

  test "trace:events:list returns persisted trace events", %{project: project, socket: socket} do
    {:ok, thread} = Avcs.Threads.ensure_default(project)
    {:ok, created} = Avcs.Turns.create_user_turn(project, thread["id"], "Trace this", [])

    {:ok, _turn} =
      Avcs.Turns.update_turn_status(project, created["turn"]["id"], "completed", "codex-turn-1")

    {:ok, custom_event} =
      Avcs.Trace.append_event(project, %{
        scope: "item",
        event_name: "item_completed",
        thread_id: thread["id"],
        turn_id: created["turn"]["id"],
        codex_item_id: "codex-item-1",
        status: "completed",
        payload: %{"futureField" => %{"version" => 2}},
        raw: %{"method" => "item/completed", "params" => %{"futureField" => true}},
        id: "trace-json-1"
      })

    ref = push(socket, "trace:events:list", %{"thread_id" => thread["id"]})

    assert_reply ref, :ok, %{success: true, data: %{items: events}}
    assert Enum.any?(events, &(&1["event_name"] == "turn_created"))
    assert Enum.any?(events, &(&1["event_name"] == "turn_status_changed"))
    assert event = Enum.find(events, &(&1["id"] == custom_event["id"]))
    assert event["payload"] == %{"futureField" => %{"version" => 2}}
    assert event["raw"] == %{"method" => "item/completed", "params" => %{"futureField" => true}}
    assert event["omitted"] == []
  end

  test "trace:events:list filters by turn_id", %{project: project, socket: socket} do
    {:ok, thread} = Avcs.Threads.ensure_default(project)
    {:ok, first} = Avcs.Turns.create_user_turn(project, thread["id"], "First", [])
    {:ok, second} = Avcs.Turns.create_user_turn(project, thread["id"], "Second", [])

    {:ok, _event} =
      Avcs.Trace.append_event(project, %{
        scope: "turn",
        event_name: "second_only",
        thread_id: thread["id"],
        turn_id: second["turn"]["id"],
        payload: %{"marker" => "second"}
      })

    ref =
      push(socket, "trace:events:list", %{
        "thread_id" => thread["id"],
        "turn_id" => first["turn"]["id"]
      })

    assert_reply ref, :ok, %{success: true, data: %{items: events}}
    assert events != []
    assert Enum.all?(events, &(&1["turn_id"] == first["turn"]["id"]))
    refute Enum.any?(events, &(&1["event_name"] == "second_only"))
  end

  test "board:items:update saves multiple output board items and broadcasts updates", %{
    project: project,
    socket: socket
  } do
    File.write!(Path.join([project["folder_path"], "output", "one.png"]), test_png())
    File.write!(Path.join([project["folder_path"], "output", "two.png"]), test_png_alt())
    assert {:ok, _scan_results} = Avcs.Assets.scan_project(project)
    assert {:ok, [first, second]} = Avcs.Board.list_items(project)

    ref =
      push(socket, "board:items:update", %{
        "items" => [
          %{"id" => first["id"], "x" => 120, "y" => 80, "z_index" => 2},
          %{
            "id" => second["id"],
            "x" => 260,
            "y" => 90,
            "display_width" => 32,
            "display_height" => 40,
            "z_index" => 1
          }
        ]
      })

    assert_reply ref, :ok, %{success: true, data: %{items: items}}
    assert length(items) == 2
    assert updated_first = Enum.find(items, &(&1["id"] == first["id"]))
    assert updated_second = Enum.find(items, &(&1["id"] == second["id"]))
    assert updated_first["x"] == 120.0
    assert updated_first["y"] == 80.0
    assert updated_first["z_index"] == 2
    assert updated_second["display_width"] == 64.0
    assert updated_second["display_height"] == 64.0
    assert updated_second["z_index"] == 1

    assert_push "board:item:updated", %{item: pushed_first}
    assert_push "board:item:updated", %{item: pushed_second}

    assert MapSet.new([pushed_first["id"], pushed_second["id"]]) ==
             MapSet.new([first["id"], second["id"]])
  end

  test "board:items:update rejects missing ids and invalid numbers", %{
    project: project,
    socket: socket
  } do
    File.write!(Path.join([project["folder_path"], "output", "one.png"]), test_png())
    assert {:ok, _scan_results} = Avcs.Assets.scan_project(project)
    assert {:ok, [item]} = Avcs.Board.list_items(project)

    invalid_ref =
      push(socket, "board:items:update", %{
        "items" => [%{"id" => item["id"], "x" => "not-a-number"}]
      })

    assert_reply invalid_ref, :ok, %{
      success: false,
      error: %{code: "invalid_board_item_update"}
    }

    invalid_z_index_ref =
      push(socket, "board:items:update", %{
        "items" => [%{"id" => item["id"], "z_index" => "2.5"}]
      })

    assert_reply invalid_z_index_ref, :ok, %{
      success: false,
      error: %{code: "invalid_board_item_update"}
    }

    missing_ref =
      push(socket, "board:items:update", %{
        "items" => [%{"id" => Ecto.UUID.generate(), "x" => 10}]
      })

    assert_reply missing_ref, :ok, %{
      success: false,
      error: %{code: "board_item_not_found"}
    }
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

  defp test_png_alt do
    Base.decode64!(
      "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADUlEQVR42mP8z8BQDwAFgwJ/lK3teQAAAABJRU5ErkJggg=="
    )
  end

  defp wait_until(fun) do
    deadline = System.monotonic_time(:millisecond) + 1_000
    do_wait_until(fun, deadline)
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

  defp do_wait_until(fun, deadline) do
    if fun.() do
      :ok
    else
      if System.monotonic_time(:millisecond) > deadline do
        flunk("condition was not met before timeout")
      else
        Process.sleep(10)
        do_wait_until(fun, deadline)
      end
    end
  end
end
