defmodule Avcs.Agent.RunnerTest do
  use ExUnit.Case, async: false

  defmodule ThreadNameCodexClient do
    @large_image_result String.duplicate("A", 150_000)
    @recovered_image_path Path.join(System.tmp_dir!(), "avcs-recovered-image.png")

    def run_turn(_project, _codex_thread_id, _text, _reference_paths, on_event) do
      on_event.({:thread_name_updated, %{"threadName" => "Generated logo concepts"}, %{}})

      on_event.(
        {:item_started,
         %{"id" => "tool-1", "type" => "commandExecution", "command" => "echo render"}, %{}}
      )

      on_event.(
        {:item_completed,
         %{
           "id" => "tool-1",
           "type" => "commandExecution",
           "command" => "echo render",
           "status" => "completed"
         }, %{}}
      )

      image_started = %{
        "id" => "image-1",
        "type" => "imageGeneration",
        "status" => "in_progress"
      }

      image_completed =
        Map.merge(image_started, %{
          "status" => "completed",
          "savedPath" => "/tmp/fake-image.png",
          "result" => @large_image_result
        })

      on_event.({:item_started, image_started, %{}})
      on_event.({:item_completed, image_completed, %{}})

      approval_started = approval_review("inProgress")

      on_event.(
        {:approval_review_started, approval_started, raw_approval("started", approval_started)}
      )

      approval_completed =
        approval_started
        |> Map.merge(%{
          "completedAtMs" => 1_700_000_000_200,
          "decisionSource" => "agent",
          "review" => %{"status" => "denied", "riskLevel" => "high"}
        })

      on_event.(
        {:approval_review_completed, approval_completed,
         raw_approval("completed", approval_completed)}
      )

      {:ok,
       %{
         codex_thread_id: "codex-thread-1",
         codex_turn_id: "codex-turn-1",
         assistant_text: "Done",
         items: [image_completed],
         thread_name: "Generated logo concepts"
       }}
    end

    def read_thread("codex-thread-1", include_turns: true) do
      {:ok,
       %{
         "id" => "codex-thread-1",
         "name" => "Recovered image thread",
         "turns" => [
           %{
             "id" => "codex-turn-1",
             "status" => "completed",
             "items" => [
               %{
                 "id" => "user-1",
                 "type" => "userMessage",
                 "content" => [%{"type" => "text", "text" => "Make an image"}]
               },
               %{
                 "id" => "image-1",
                 "type" => "imageGeneration",
                 "status" => "completed",
                 "savedPath" => @recovered_image_path,
                 "result" => @large_image_result
               },
               %{"id" => "agent-1", "type" => "agentMessage", "text" => "Done"}
             ]
           }
         ]
       }}
    end

    def recovered_image_path, do: @recovered_image_path

    defp approval_review(status) do
      %{
        "threadId" => "codex-thread-1",
        "turnId" => "codex-turn-1",
        "reviewId" => "review-1",
        "targetItemId" => "tool-1",
        "startedAtMs" => 1_700_000_000_100,
        "action" => %{
          "type" => "command",
          "command" => "echo render",
          "cwd" => File.cwd!(),
          "source" => "shell"
        },
        "review" => %{"status" => status, "riskLevel" => "high"}
      }
    end

    defp raw_approval(phase, params) do
      %{"method" => "item/autoApprovalReview/#{phase}", "params" => params}
    end
  end

  defmodule TurnStartedCodexClient do
    def run_turn(_project, _codex_thread_id, _text, _reference_paths, on_event) do
      on_event.(
        {:turn_started, %{"id" => "codex-turn-from-start"},
         %{"params" => %{"threadId" => "codex-thread-from-turn-start"}}}
      )

      {:error, "simulated failure"}
    end
  end

  defmodule ItemNotificationCodexClient do
    def run_turn(_project, _codex_thread_id, _text, _reference_paths, on_event) do
      on_event.(
        {:item_started,
         %{"id" => "tool-from-item", "type" => "commandExecution", "command" => "echo ok"},
         %{"params" => %{"threadId" => "codex-thread-from-item"}}}
      )

      {:error, "simulated failure"}
    end
  end

  defmodule InterruptedCodexClient do
    def run_turn(_project, _codex_thread_id, _text, _reference_paths, _on_event, _settings) do
      {:error, :interrupted}
    end
  end

  defmodule MaskInstructionCodexClient do
    def run_turn(_project, _codex_thread_id, text, reference_paths, _on_event, _settings) do
      send(Application.fetch_env!(:avcs, :agent_runner_test_pid), {
        :mask_run,
        text,
        reference_paths
      })

      {:ok,
       %{
         codex_thread_id: "codex-mask-thread",
         codex_turn_id: "codex-mask-turn",
         assistant_text: "",
         items: [],
         thread_name: nil
       }}
    end
  end

  defmodule DataProviderInstructionCodexClient do
    def run_turn(_project, _codex_thread_id, text, _reference_paths, _on_event, _settings) do
      send(Application.fetch_env!(:avcs, :agent_runner_test_pid), {:provider_run, text})

      {:ok,
       %{
         codex_thread_id: "codex-provider-thread",
         codex_turn_id: "codex-provider-turn",
         assistant_text: "Done",
         items: [
           %{
             "id" => "provider-1",
             "type" => "commandExecution",
             "command" => "python priv/skills/avcs-data-prodiver-apod/scripts/fetch_apod.py",
             "status" => "completed",
             "stdout" =>
               Jason.encode!(%{
                 "status" => "success",
                 "data" => %{
                   "date" => "2026-06-01",
                   "title" => "APOD title",
                   "media_type" => "image",
                   "source" => "api",
                   "image_path" => "/tmp/apod.png",
                   "apod_url" => "https://apod.nasa.gov/apod/astropix.html"
                 }
               })
           }
         ],
         thread_name: nil
       }}
    end
  end

  setup do
    previous_client = Application.get_env(:avcs, :codex_client)
    previous_codex_home = Application.get_env(:avcs, :codex_home)
    previous_test_pid = Application.get_env(:avcs, :agent_runner_test_pid)
    Application.put_env(:avcs, :codex_client, ThreadNameCodexClient)

    project_dir =
      Path.join(System.tmp_dir!(), "avcs-agent-runner-#{System.unique_integer([:positive])}")

    File.rm_rf!(project_dir)
    {:ok, project} = Avcs.Projects.open_project(project_dir)

    on_exit(fn ->
      if previous_client do
        Application.put_env(:avcs, :codex_client, previous_client)
      else
        Application.delete_env(:avcs, :codex_client)
      end

      if previous_codex_home do
        Application.put_env(:avcs, :codex_home, previous_codex_home)
      else
        Application.delete_env(:avcs, :codex_home)
      end

      if previous_test_pid do
        Application.put_env(:avcs, :agent_runner_test_pid, previous_test_pid)
      else
        Application.delete_env(:avcs, :agent_runner_test_pid)
      end

      File.rm_rf!(project_dir)
    end)

    %{project: project}
  end

  test "syncs Codex app-server thread name into the local thread title", %{project: project} do
    {:ok, thread} = Avcs.Threads.create_thread(project, "Untitled thread")
    {:ok, created} = Avcs.Turns.create_user_turn(project, thread["id"], "Make logo options", [])

    {:ok, pid} =
      Avcs.Agent.Runner.start(
        project,
        thread["id"],
        created["turn"]["id"],
        "Make logo options",
        []
      )

    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 1_000

    {:ok, synced} = Avcs.Threads.get_thread(project, thread["id"])
    assert synced["codex_thread_id"] == "codex-thread-1"
    assert synced["title"] == "Generated logo concepts"

    {:ok, items} = Avcs.Turns.list_items(project, thread["id"])
    assert Enum.any?(items, &(&1["role"] == "assistant" and &1["content"] == "Done"))

    assert tool_item =
             Enum.find(items, &(&1["codex_item_id"] == "tool-1" and &1["type"] == "tool_result"))

    assert tool_item["status"] == "completed"
    assert tool_item["content"] == "echo render"
    assert tool_item["payload"]["tool_name"] == "command"

    assert approval_item =
             Enum.find(
               items,
               &(&1["codex_item_id"] == "review-1" and &1["type"] == "approval_request")
             )

    assert approval_item["status"] == "denied"
    assert approval_item["content"] == "echo render"
    assert approval_item["payload"]["review_id"] == "review-1"
    assert approval_item["payload"]["target_item_id"] == "tool-1"
    assert approval_item["payload"]["event"]["action"]["type"] == "command"
  end

  test "marks interrupted turns without creating an error item", %{project: project} do
    Application.put_env(:avcs, :codex_client, InterruptedCodexClient)

    {:ok, thread} = Avcs.Threads.create_thread(project, "Interrupted thread")
    {:ok, created} = Avcs.Turns.create_user_turn(project, thread["id"], "Stop this", [])

    {:ok, pid} =
      Avcs.Agent.Runner.start(
        project,
        thread["id"],
        created["turn"]["id"],
        "Stop this",
        []
      )

    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 1_000

    {:ok, [turn]} = Avcs.Turns.list_turns(project, thread["id"])
    assert turn["status"] == "interrupted"
    assert turn["completed_at"]
    assert turn["error"] == "Stopped by user"

    {:ok, items} = Avcs.Turns.list_items(project, thread["id"])
    refute Enum.any?(items, &(&1["type"] == "error"))
  end

  test "adds visual mask edit instructions to the Codex turn", %{project: project} do
    Application.put_env(:avcs, :codex_client, MaskInstructionCodexClient)
    Application.put_env(:avcs, :agent_runner_test_pid, self())

    {:ok, thread} = Avcs.Threads.create_thread(project, "Mask edit thread")
    base_path = Path.join([project["folder_path"], "output", "base.png"])
    mask_path = Path.join([project["folder_path"], ".avcs", "cache", "temp", "masks", "mask.png"])
    File.mkdir_p!(Path.dirname(mask_path))
    File.write!(base_path, test_png())
    File.write!(mask_path, test_png_alt())
    {:ok, base_asset} = Avcs.Assets.upsert_asset(project, base_path, source: "generated")
    {:ok, mask_asset} = Avcs.Assets.upsert_asset(project, mask_path, source: "mask")

    mask_edit = %{
      "mode" => "visual_reference",
      "base_asset_id" => base_asset["id"],
      "mask_asset_id" => mask_asset["id"],
      "mask_semantics" => "white_edit_black_keep"
    }

    {:ok, created} =
      Avcs.Turns.create_user_turn(
        project,
        thread["id"],
        "Replace the marked area",
        [base_asset["id"], mask_asset["id"]],
        mask_edit: mask_edit
      )

    {:ok, pid} =
      Avcs.Agent.Runner.start(
        project,
        thread["id"],
        created["turn"]["id"],
        "Replace the marked area",
        [base_asset["id"], mask_asset["id"]],
        %{mask_edit: mask_edit}
      )

    ref = Process.monitor(pid)

    assert_receive {:mask_run, text, reference_paths}, 1_000
    assert text =~ "Replace the marked area"
    assert text =~ "Mask edit reference instructions"
    assert text =~ "white or marked areas indicate the region to change"
    assert reference_paths == [base_path, mask_path]
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 1_000
  end

  test "adds data provider instructions and persists provider context", %{project: project} do
    Application.put_env(:avcs, :codex_client, DataProviderInstructionCodexClient)
    Application.put_env(:avcs, :agent_runner_test_pid, self())

    {:ok, thread} = Avcs.Threads.create_thread(project, "Provider thread")

    data_provider = %{
      "slug" => "avcs-data-prodiver-apod",
      "name" => "NASA APOD",
      "version" => "0.1.0",
      "loaded" => true
    }

    {:ok, created} =
      Avcs.Turns.create_user_turn(
        project,
        thread["id"],
        "Create from APOD",
        [],
        data_provider: data_provider
      )

    {:ok, pid} =
      Avcs.Agent.Runner.start(
        project,
        thread["id"],
        created["turn"]["id"],
        "Create from APOD",
        [],
        %{data_provider: data_provider}
      )

    ref = Process.monitor(pid)

    assert_receive {:provider_run, text}, 1_000
    assert text =~ "Data provider selected for this turn"
    assert text =~ "fetch_apod.py"
    assert text =~ "After the provider data is available"
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 1_000

    {:ok, items} = Avcs.Turns.list_items(project, thread["id"])
    assert assistant = Enum.find(items, &(&1["type"] == "assistant_message"))
    assert assistant["payload"]["provider_context"]["provider"]["slug"] == data_provider["slug"]
    assert assistant["payload"]["provider_context"]["result"]["title"] == "APOD title"
  end

  test "persists completed image generation items without large result payload", %{
    project: project
  } do
    {:ok, thread} = Avcs.Threads.create_thread(project, "Image thread")
    {:ok, created} = Avcs.Turns.create_user_turn(project, thread["id"], "Make an image", [])

    {:ok, pid} =
      Avcs.Agent.Runner.start(
        project,
        thread["id"],
        created["turn"]["id"],
        "Make an image",
        []
      )

    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 1_000

    {:ok, items} = Avcs.Turns.list_items(project, thread["id"])

    assert image_item =
             Enum.find(items, &(&1["codex_item_id"] == "image-1" and &1["type"] == "tool_result"))

    assert image_item["status"] == "completed"
    assert image_item["payload"]["tool_name"] == "image generation"
    assert image_item["payload"]["codex_item"]["savedPath"] == "/tmp/fake-image.png"
    refute Map.has_key?(image_item["payload"]["codex_item"], "result")
    assert image_item["payload"]["codex_item"]["result_omitted"] == true
    assert image_item["payload"]["codex_item"]["result_size_bytes"] == 150_000

    assert assistant_item =
             Enum.find(items, &(&1["type"] == "assistant_message" and &1["content"] == "Done"))

    assert assistant_image =
             Enum.find(
               assistant_item["payload"]["codex_items"],
               &(&1["id"] == "image-1" and &1["type"] == "imageGeneration")
             )

    refute Map.has_key?(assistant_image, "result")
    assert assistant_image["result_omitted"] == true
    assert assistant_image["result_size_bytes"] == 150_000
  end

  test "repair_thread reconciles Codex thread/read turns into local state", %{project: project} do
    File.write!(ThreadNameCodexClient.recovered_image_path(), test_png())
    on_exit(fn -> File.rm(ThreadNameCodexClient.recovered_image_path()) end)

    {:ok, thread} = Avcs.Threads.create_thread(project, "Broken image thread")
    {:ok, :ok} = Avcs.Threads.set_codex_thread_id(project, thread["id"], "codex-thread-1")
    {:ok, created} = Avcs.Turns.create_user_turn(project, thread["id"], "Make an image", [])

    {:ok, _running_image} =
      Avcs.Turns.upsert_codex_item(project,
        turn_id: created["turn"]["id"],
        thread_id: thread["id"],
        codex_item_id: "image-1",
        type: "tool_call",
        role: "tool",
        content: "Image generation",
        status: "running",
        payload: %{
          tool_name: "image generation",
          codex_item: %{"id" => "image-1", "type" => "imageGeneration", "status" => "in_progress"}
        }
      )

    assert {:ok, repair} = Avcs.Agent.Runner.repair_thread(project, thread["id"])
    assert repair.matched_turns == 1
    assert repair.synced_items == 3
    assert repair.imported_images == 1

    {:ok, [turn]} = Avcs.Turns.list_turns(project, thread["id"])
    assert turn["codex_turn_id"] == "codex-turn-1"
    assert turn["status"] == "completed"

    {:ok, items} = Avcs.Turns.list_items(project, thread["id"])

    assert image_item =
             Enum.find(items, &(&1["codex_item_id"] == "image-1" and &1["type"] == "tool_result"))

    assert image_item["status"] == "completed"
    assert image_item["payload"]["recovered"] == true

    assert image_item["payload"]["codex_item"]["savedPath"] ==
             ThreadNameCodexClient.recovered_image_path()

    refute Map.has_key?(image_item["payload"]["codex_item"], "result")

    assert Enum.any?(
             items,
             &(&1["codex_item_id"] == "agent-1" and &1["type"] == "assistant_message")
           )

    assert Enum.any?(items, &(&1["type"] == "image_asset"))

    {:ok, [asset]} = Avcs.Assets.list_assets(project)
    assert asset["source"] == "generated"
    assert String.starts_with?(asset["relative_path"], "output/")
  end

  test "repair_thread recovers missing Codex thread id from matching session rollout", %{
    project: project
  } do
    File.write!(ThreadNameCodexClient.recovered_image_path(), test_png())
    on_exit(fn -> File.rm(ThreadNameCodexClient.recovered_image_path()) end)

    codex_home =
      Path.join(System.tmp_dir!(), "avcs-codex-home-#{System.unique_integer([:positive])}")

    Application.put_env(:avcs, :codex_home, codex_home)
    session_dir = Path.join([codex_home, "sessions", "2026", "06", "02"])
    File.mkdir_p!(session_dir)

    session_path =
      Path.join(session_dir, "rollout-2026-06-02T00-00-00-codex-thread-1.jsonl")

    File.write!(session_path, [
      Jason.encode!(%{
        "type" => "session_meta",
        "payload" => %{
          "id" => "codex-thread-1",
          "cwd" => Avcs.Projects.folder_path(project),
          "originator" => "avcs"
        }
      }),
      "\n",
      Jason.encode!(%{"type" => "response_item", "payload" => %{"id" => "image-1"}}),
      "\n"
    ])

    on_exit(fn -> File.rm_rf!(codex_home) end)

    {:ok, thread} = Avcs.Threads.create_thread(project, "Broken unlinked image thread")
    {:ok, created} = Avcs.Turns.create_user_turn(project, thread["id"], "Make an image", [])

    {:ok, _running_image} =
      Avcs.Turns.upsert_codex_item(project,
        turn_id: created["turn"]["id"],
        thread_id: thread["id"],
        codex_item_id: "image-1",
        type: "tool_call",
        role: "tool",
        content: "Image generation",
        status: "running",
        payload: %{
          tool_name: "image generation",
          codex_item: %{"id" => "image-1", "type" => "imageGeneration", "status" => "in_progress"}
        }
      )

    assert {:ok, repair} = Avcs.Agent.Runner.repair_thread(project, thread["id"])
    assert repair.codex_thread_id == "codex-thread-1"
    assert repair.matched_turns == 1

    {:ok, synced} = Avcs.Threads.get_thread(project, thread["id"])
    assert synced["codex_thread_id"] == "codex-thread-1"
  end

  test "persists Codex thread id from turn_started before run completion", %{project: project} do
    Application.put_env(:avcs, :codex_client, TurnStartedCodexClient)

    {:ok, thread} = Avcs.Threads.create_thread(project, "Early thread id")
    {:ok, created} = Avcs.Turns.create_user_turn(project, thread["id"], "Fail after start", [])

    {:ok, pid} =
      Avcs.Agent.Runner.start(
        project,
        thread["id"],
        created["turn"]["id"],
        "Fail after start",
        []
      )

    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 1_000

    {:ok, synced} = Avcs.Threads.get_thread(project, thread["id"])
    assert synced["codex_thread_id"] == "codex-thread-from-turn-start"

    {:ok, [turn]} = Avcs.Turns.list_turns(project, thread["id"])
    assert turn["codex_turn_id"] == "codex-turn-from-start"
    assert turn["status"] == "failed"
  end

  test "persists Codex thread id from item notification when thread is still unlinked", %{
    project: project
  } do
    Application.put_env(:avcs, :codex_client, ItemNotificationCodexClient)

    {:ok, thread} = Avcs.Threads.create_thread(project, "Item fallback thread id")
    {:ok, created} = Avcs.Turns.create_user_turn(project, thread["id"], "Fail after item", [])

    {:ok, pid} =
      Avcs.Agent.Runner.start(
        project,
        thread["id"],
        created["turn"]["id"],
        "Fail after item",
        []
      )

    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 1_000

    {:ok, synced} = Avcs.Threads.get_thread(project, thread["id"])
    assert synced["codex_thread_id"] == "codex-thread-from-item"

    {:ok, items} = Avcs.Turns.list_items(project, thread["id"])

    assert Enum.any?(
             items,
             &(&1["codex_item_id"] == "tool-from-item" and &1["type"] == "tool_call")
           )
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
end
