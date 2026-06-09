defmodule Avcs.Agent.RunnerTest do
  use ExUnit.Case, async: false

  alias Avcs.HTTPTestServer

  defmodule ThreadNameHarness do
    @large_image_result String.duplicate("A", 150_000)
    @recovered_image_path Path.join(System.tmp_dir!(), "avcs-recovered-image.png")

    def run_turn(
          _project,
          _avcs_thread_id,
          _avcs_turn_id,
          _remote_thread_id,
          _text,
          _reference_paths,
          on_event,
          _opts
        ) do
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
         remote_thread_id: "codex-thread-1",
         remote_turn_id: "codex-turn-1",
         assistant_text: "Done",
         items: [image_completed],
         thread_name: "Generated logo concepts"
       }}
    end

    def read_thread("codex-thread-1", opts) do
      true = Keyword.get(opts, :include_turns)

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

  defmodule TurnStartedHarness do
    def run_turn(
          _project,
          _avcs_thread_id,
          _avcs_turn_id,
          _remote_thread_id,
          _text,
          _reference_paths,
          on_event,
          _opts
        ) do
      on_event.(
        {:turn_started, %{"id" => "codex-turn-from-start"},
         %{"params" => %{"threadId" => "codex-thread-from-turn-start"}}}
      )

      {:error, "simulated failure"}
    end
  end

  defmodule ItemNotificationHarness do
    def run_turn(
          _project,
          _avcs_thread_id,
          _avcs_turn_id,
          _remote_thread_id,
          _text,
          _reference_paths,
          on_event,
          _opts
        ) do
      on_event.(
        {:item_started,
         %{"id" => "tool-from-item", "type" => "commandExecution", "command" => "echo ok"},
         %{"params" => %{"threadId" => "codex-thread-from-item"}}}
      )

      {:error, "simulated failure"}
    end
  end

  defmodule InterruptedHarness do
    def run_turn(
          _project,
          _avcs_thread_id,
          _avcs_turn_id,
          _remote_thread_id,
          _text,
          _reference_paths,
          _on_event,
          _opts
        ) do
      {:error, :interrupted}
    end
  end

  defmodule MaskInstructionHarness do
    def run_turn(
          _project,
          _avcs_thread_id,
          _avcs_turn_id,
          _remote_thread_id,
          text,
          reference_paths,
          _on_event,
          _opts
        ) do
      send(Application.fetch_env!(:avcs, :agent_runner_test_pid), {
        :mask_run,
        text,
        reference_paths
      })

      {:ok,
       %{
         remote_thread_id: "codex-mask-thread",
         remote_turn_id: "codex-mask-turn",
         assistant_text: "",
         items: [],
         thread_name: nil
       }}
    end
  end

  defmodule DataProviderInstructionHarness do
    def run_turn(
          _project,
          _avcs_thread_id,
          _avcs_turn_id,
          _remote_thread_id,
          text,
          _reference_paths,
          _on_event,
          _opts
        ) do
      send(Application.fetch_env!(:avcs, :agent_runner_test_pid), {:provider_run, text})

      {:ok,
       %{
         remote_thread_id: "codex-provider-thread",
         remote_turn_id: "codex-provider-turn",
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

  defmodule EditRerunHarness do
    def prepare_rerun(
          _project,
          _avcs_thread_id,
          _avcs_turn_id,
          remote_thread_id,
          rollback_turn_count,
          _opts
        ) do
      send(
        Application.fetch_env!(:avcs, :agent_runner_test_pid),
        {:fork_thread, remote_thread_id}
      )

      send(Application.fetch_env!(:avcs, :agent_runner_test_pid), {
        :rollback_thread,
        "codex-thread-forked",
        rollback_turn_count
      })

      {:ok, %{remote_thread_id: "codex-thread-forked"}}
    end

    def run_turn(
          _project,
          _avcs_thread_id,
          _avcs_turn_id,
          remote_thread_id,
          text,
          _reference_paths,
          _on_event,
          _opts
        ) do
      send(Application.fetch_env!(:avcs, :agent_runner_test_pid), {
        :rerun_turn,
        remote_thread_id,
        text
      })

      {:ok,
       %{
         remote_thread_id: remote_thread_id,
         remote_turn_id: "codex-rerun-turn",
         assistant_text: "Rerun done",
         items: [],
         thread_name: nil
       }}
    end
  end

  defmodule AvcsAgentSteerClient do
    def configured?, do: true

    def chat_completion_stream(messages, _tools, _opts, on_event, _interrupted?) do
      call_index = Process.get(:avcs_agent_steer_client_calls, 0) + 1
      Process.put(:avcs_agent_steer_client_calls, call_index)

      send(Application.fetch_env!(:avcs, :agent_runner_test_pid), {
        :avcs_agent_steer_call,
        call_index,
        self(),
        messages
      })

      case call_index do
        1 ->
          receive do
            :finish_first_avcs_agent_call -> :ok
          after
            1_000 -> :ok
          end

          on_event.({:assistant_delta, "First response.", %{}})

          {:ok,
           %{
             assistant_text: "First response.",
             tool_calls: [],
             remote_turn_id: "avcs-agent-remote-turn-1",
             remote_model: "fake-text-model"
           }}

        _index ->
          on_event.({:assistant_delta, " Continuation response.", %{}})

          {:ok,
           %{
             assistant_text: " Continuation response.",
             tool_calls: [],
             remote_turn_id: "avcs-agent-remote-turn-2",
             remote_model: "fake-text-model"
           }}
      end
    end

    def generate_image(_prompt, _opts), do: {:error, :unexpected_image_generation}
  end

  defmodule AvcsAgentImageToolClient do
    def configured?, do: true

    def chat_completion_stream(_messages, tools, _opts, on_event, _interrupted?) do
      call_index = Process.get(:avcs_agent_image_tool_client_calls, 0) + 1
      Process.put(:avcs_agent_image_tool_client_calls, call_index)

      send(Application.fetch_env!(:avcs, :agent_runner_test_pid), {
        :avcs_agent_image_tool_call,
        call_index,
        tools
      })

      case call_index do
        1 ->
          {:ok,
           %{
             assistant_text: "",
             tool_calls: [
               %{
                 "id" => "tool-image-1",
                 "name" => "image_gen",
                 "arguments" =>
                   Jason.encode!(%{
                     "prompt" => "A precise Avcs test image",
                     "count" => 1,
                     "aspect_ratio" => "1:1"
                   })
               }
             ],
             remote_turn_id: "avcs-agent-image-turn-1",
             remote_model: "fake-text-model"
           }}

        _index ->
          on_event.({:assistant_delta, "Saved image.", %{}})

          {:ok,
           %{
             assistant_text: "Saved image.",
             tool_calls: [],
             remote_turn_id: "avcs-agent-image-turn-2",
             remote_model: "fake-text-model"
           }}
      end
    end

    def generate_image(prompt, opts) do
      send(Application.fetch_env!(:avcs, :agent_runner_test_pid), {
        :avcs_agent_generate_image,
        prompt,
        opts
      })

      {:ok,
       %{
         model: Keyword.get(opts, :model) || "fake-image-model",
         images: [%{base64: Base.encode64(test_png()), mime_type: "image/png"}],
         raw_id: "fake-image-response"
       }}
    end

    defp test_png do
      Base.decode64!(
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII="
      )
    end
  end

  defmodule AvcsAgentImageReferenceClient do
    def configured?, do: true

    def chat_completion_stream(_messages, tools, _opts, on_event, _interrupted?) do
      call_index = Process.get(:avcs_agent_reference_image_client_calls, 0) + 1
      Process.put(:avcs_agent_reference_image_client_calls, call_index)

      send(Application.fetch_env!(:avcs, :agent_runner_test_pid), {
        :avcs_agent_reference_image_call,
        call_index,
        tools
      })

      case call_index do
        1 ->
          asset_id = Application.fetch_env!(:avcs, :agent_runner_reference_asset_id)
          mask_asset_id = Application.fetch_env!(:avcs, :agent_runner_reference_mask_asset_id)

          {:ok,
           %{
             assistant_text: "",
             tool_calls: [
               %{
                 "id" => "tool-image-reference-1",
                 "name" => "image_gen",
                 "arguments" =>
                   Jason.encode!(%{
                     "prompt" => "Create a variant using the referenced asset.",
                     "count" => 1,
                     "reference_asset_ids" => [asset_id],
                     "mask_asset_id" => mask_asset_id,
                     "size" => "1024x1024",
                     "quality" => "high",
                     "output_format" => "jpeg",
                     "output_compression" => 80,
                     "background" => "opaque",
                     "moderation" => "low"
                   })
               }
             ],
             remote_turn_id: "avcs-agent-reference-image-turn-1",
             remote_model: "fake-text-model"
           }}

        _index ->
          on_event.({:assistant_delta, "Saved referenced image.", %{}})

          {:ok,
           %{
             assistant_text: "Saved referenced image.",
             tool_calls: [],
             remote_turn_id: "avcs-agent-reference-image-turn-2",
             remote_model: "fake-text-model"
           }}
      end
    end

    def generate_image(prompt, opts) do
      reference_images =
        opts
        |> Keyword.get(:reference_images, [])
        |> Enum.map(&Map.take(&1, [:asset_id, :path, :relative_path, :file_name, :mime_type]))

      mask_image =
        opts
        |> Keyword.get(:mask_image)
        |> case do
          nil -> nil
          image -> Map.take(image, [:asset_id, :path, :relative_path, :file_name, :mime_type])
        end

      send(Application.fetch_env!(:avcs, :agent_runner_test_pid), {
        :avcs_agent_reference_generate_image,
        prompt,
        reference_images,
        mask_image,
        Keyword.drop(opts, [:reference_images, :mask_image])
      })

      {:ok,
       %{
         model: Keyword.get(opts, :model) || "fake-image-model",
         images: [%{base64: Base.encode64(test_png()), mime_type: "image/png"}],
         raw_id: "fake-reference-image-response"
       }}
    end

    defp test_png do
      Base.decode64!(
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII="
      )
    end
  end

  defmodule AvcsAgentImageFinalTimeoutClient do
    def configured?, do: true

    def chat_completion_stream(_messages, tools, _opts, _on_event, _interrupted?) do
      call_index = Process.get(:avcs_agent_image_timeout_client_calls, 0) + 1
      Process.put(:avcs_agent_image_timeout_client_calls, call_index)

      send(Application.fetch_env!(:avcs, :agent_runner_test_pid), {
        :avcs_agent_image_timeout_call,
        call_index,
        tools
      })

      case call_index do
        1 ->
          {:ok,
           %{
             assistant_text: "",
             tool_calls: [
               %{
                 "id" => "tool-image-timeout-1",
                 "name" => "image_gen",
                 "arguments" =>
                   Jason.encode!(%{
                     "prompt" => "A timeout regression test image",
                     "count" => 1,
                     "aspect_ratio" => "1:1"
                   })
               }
             ],
             remote_turn_id: "avcs-agent-image-timeout-turn-1",
             remote_model: "fake-text-model"
           }}

        _index ->
          {:error, :timeout}
      end
    end

    def generate_image(prompt, opts) do
      send(Application.fetch_env!(:avcs, :agent_runner_test_pid), {
        :avcs_agent_timeout_generate_image,
        prompt,
        opts
      })

      {:ok,
       %{
         model: Keyword.get(opts, :model) || "fake-image-model",
         images: [%{base64: Base.encode64(test_png()), mime_type: "image/png"}],
         raw_id: "fake-image-timeout-response"
       }}
    end

    defp test_png do
      Base.decode64!(
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII="
      )
    end
  end

  defmodule AvcsAgentApodWorkflowClient do
    def configured?, do: true

    def chat_completion_stream(messages, tools, _opts, on_event, _interrupted?) do
      call_index = Process.get(:avcs_agent_apod_workflow_calls, 0) + 1
      Process.put(:avcs_agent_apod_workflow_calls, call_index)

      send(Application.fetch_env!(:avcs, :agent_runner_test_pid), {
        :avcs_agent_apod_workflow_call,
        call_index,
        messages,
        Enum.map(tools, &get_in(&1, ["function", "name"]))
      })

      case call_index do
        1 ->
          {:ok,
           %{
             assistant_text: "",
             tool_calls: [
               %{
                 "id" => "tool-apod-1",
                 "name" => "bash",
                 "arguments" =>
                   Jason.encode!(%{
                     "command_kind" => "data_provider",
                     "provider" => "apod",
                     "args" => %{"date" => "2026-06-01"}
                   })
               }
             ],
             remote_turn_id: "avcs-agent-apod-turn-1",
             remote_model: "fake-text-model"
           }}

        2 ->
          {:ok,
           %{
             assistant_text: "",
             tool_calls: [
               %{
                 "id" => "tool-image-after-apod",
                 "name" => "image_gen",
                 "arguments" =>
                   Jason.encode!(%{
                     "prompt" => "Create a poster using Fake APOD source data.",
                     "count" => 1
                   })
               }
             ],
             remote_turn_id: "avcs-agent-apod-turn-2",
             remote_model: "fake-text-model"
           }}

        _index ->
          on_event.({:assistant_delta, "Created an APOD poster.", %{}})

          {:ok,
           %{
             assistant_text: "Created an APOD poster.",
             tool_calls: [],
             remote_turn_id: "avcs-agent-apod-turn-3",
             remote_model: "fake-text-model"
           }}
      end
    end

    def generate_image(prompt, opts) do
      send(Application.fetch_env!(:avcs, :agent_runner_test_pid), {
        :avcs_agent_apod_generate_image,
        prompt,
        opts
      })

      {:ok,
       %{
         model: Keyword.get(opts, :model) || "fake-image-model",
         images: [%{base64: Base.encode64(test_png_alt()), mime_type: "image/png"}],
         raw_id: "fake-apod-image-response"
       }}
    end

    defp test_png_alt do
      Base.decode64!(
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADUlEQVR42mP8z8BQDwAFgwJ/lK3teQAAAABJRU5ErkJggg=="
      )
    end
  end

  defmodule AvcsAgentVisionClient do
    def configured?, do: true

    def chat_completion_stream(messages, tools, _opts, on_event, _interrupted?) do
      send(Application.fetch_env!(:avcs, :agent_runner_test_pid), {
        :avcs_agent_vision_call,
        messages,
        tools
      })

      on_event.({:assistant_delta, "Saw reference.", %{}})

      {:ok,
       %{
         assistant_text: "Saw reference.",
         tool_calls: [],
         remote_turn_id: "avcs-agent-vision-turn",
         remote_model: "fake-vision-model"
       }}
    end

    def generate_image(_prompt, _opts), do: {:error, :unexpected_image_generation}
  end

  setup do
    previous_harness = Application.get_env(:avcs, :agent_harness)
    previous_avcs_agent_client = Application.get_env(:avcs, :avcs_agent_client)
    previous_codex_home = Application.get_env(:avcs, :codex_home)
    previous_test_pid = Application.get_env(:avcs, :agent_runner_test_pid)
    previous_data_provider_scripts = Application.get_env(:avcs, :data_provider_scripts)
    previous_stream_retry_attempts = Application.get_env(:avcs, :avcs_agent_stream_retry_attempts)

    previous_stream_retry_backoff =
      Application.get_env(:avcs, :avcs_agent_stream_retry_backoff_ms)

    previous_request_timeout = Application.get_env(:avcs, :avcs_agent_request_timeout_ms)
    previous_connect_timeout = Application.get_env(:avcs, :avcs_agent_connect_timeout_ms)
    Application.put_env(:avcs, :agent_harness, ThreadNameHarness)

    project_dir =
      Path.join(System.tmp_dir!(), "avcs-agent-runner-#{System.unique_integer([:positive])}")

    File.rm_rf!(project_dir)
    {:ok, project} = Avcs.Projects.open_project(project_dir)

    on_exit(fn ->
      if previous_harness do
        Application.put_env(:avcs, :agent_harness, previous_harness)
      else
        Application.delete_env(:avcs, :agent_harness)
      end

      if previous_avcs_agent_client do
        Application.put_env(:avcs, :avcs_agent_client, previous_avcs_agent_client)
      else
        Application.delete_env(:avcs, :avcs_agent_client)
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

      if previous_data_provider_scripts do
        Application.put_env(:avcs, :data_provider_scripts, previous_data_provider_scripts)
      else
        Application.delete_env(:avcs, :data_provider_scripts)
      end

      restore_app_env(:avcs_agent_stream_retry_attempts, previous_stream_retry_attempts)
      restore_app_env(:avcs_agent_stream_retry_backoff_ms, previous_stream_retry_backoff)
      restore_app_env(:avcs_agent_request_timeout_ms, previous_request_timeout)
      restore_app_env(:avcs_agent_connect_timeout_ms, previous_connect_timeout)

      File.rm_rf!(project_dir)
    end)

    %{project: project}
  end

  test "AvcsAgent turn/steer queues input into the active turn continuation", %{project: project} do
    Application.put_env(:avcs, :agent_harness, Avcs.Agent.Harness.AvcsAgent)
    Application.put_env(:avcs, :avcs_agent_client, AvcsAgentSteerClient)
    Application.put_env(:avcs, :agent_runner_test_pid, self())

    {:ok, thread} = Avcs.Threads.create_thread(project, "AvcsAgent steer")

    assert {:ok, created} =
             Avcs.Agent.Runner.submit(project, thread["id"], "Start the AvcsAgent turn", [], %{})

    assert_receive {:avcs_agent_steer_call, 1, runner_pid, first_messages}, 1_000
    assert List.last(first_messages)["content"] =~ "Start the AvcsAgent turn"

    assert {:ok, %{"steered" => true, "item" => steered_item}} =
             Avcs.Agent.Runner.submit(project, thread["id"], "Use this extra direction", [], %{})

    assert steered_item["payload"]["steered"] == true
    send(runner_pid, :finish_first_avcs_agent_call)

    assert_receive {:avcs_agent_steer_call, 2, ^runner_pid, second_messages}, 1_000
    assert Enum.any?(second_messages, &(to_string(&1["content"]) =~ "Use this extra direction"))

    wait_until(fn ->
      {:ok, turns} = Avcs.Turns.list_turns(project, thread["id"])
      Enum.any?(turns, &(&1["id"] == created["turn"]["id"] and &1["status"] == "completed"))
    end)

    {:ok, items} = Avcs.Turns.list_items(project, thread["id"])
    assert Enum.count(items, &(&1["type"] == "user_message")) == 2
    assert Enum.any?(items, &(&1["payload"]["steered"] == true))
    assert Enum.any?(items, &(&1["type"] == "assistant_message"))
  end

  test "AvcsAgent retries transient pre-commit stream failure without error item", %{
    project: project
  } do
    Application.put_env(:avcs, :agent_harness, Avcs.Agent.Harness.AvcsAgent)
    Application.put_env(:avcs, :avcs_agent_client, Avcs.Agent.AvcsAgentClient)
    Application.put_env(:avcs, :avcs_agent_stream_retry_attempts, 2)
    Application.put_env(:avcs, :avcs_agent_stream_retry_backoff_ms, [10])
    Application.put_env(:avcs, :avcs_agent_request_timeout_ms, 30)

    server =
      HTTPTestServer.start!([
        {:sleep, 90},
        {:stream, runner_text_stream("Recovered by retry.")}
      ])

    configure_actual_avcs_agent_runtime(server.port)

    try do
      {:ok, thread} = Avcs.Threads.create_thread(project, "AvcsAgent retry success")

      assert {:ok, created} =
               Avcs.Agent.Runner.submit(project, thread["id"], "Retry the model stream", [], %{})

      assert_receive {:http_request, first_request}, 1_000
      assert_receive {:http_request, second_request}, 1_000
      assert first_request.path == "/v1/chat/completions"
      assert second_request.path == "/v1/chat/completions"

      wait_until(fn ->
        {:ok, turns} = Avcs.Turns.list_turns(project, thread["id"])
        Enum.any?(turns, &(&1["id"] == created["turn"]["id"] and &1["status"] == "completed"))
      end)

      {:ok, items} = Avcs.Turns.list_items(project, thread["id"])
      refute Enum.any?(items, &(&1["type"] == "error"))

      assert Enum.any?(
               items,
               &(&1["type"] == "assistant_message" and &1["content"] == "Recovered by retry.")
             )
    after
      HTTPTestServer.stop(server)
    end
  end

  test "AvcsAgent marks turn failed after stream retry attempts are exhausted", %{
    project: project
  } do
    Application.put_env(:avcs, :agent_harness, Avcs.Agent.Harness.AvcsAgent)
    Application.put_env(:avcs, :avcs_agent_client, Avcs.Agent.AvcsAgentClient)
    Application.put_env(:avcs, :avcs_agent_stream_retry_attempts, 2)
    Application.put_env(:avcs, :avcs_agent_stream_retry_backoff_ms, [10])
    Application.put_env(:avcs, :avcs_agent_request_timeout_ms, 30)

    server =
      HTTPTestServer.start!([
        {:sleep, 90},
        {:sleep, 90}
      ])

    configure_actual_avcs_agent_runtime(server.port)

    try do
      {:ok, thread} = Avcs.Threads.create_thread(project, "AvcsAgent retry exhausted")

      assert {:ok, created} =
               Avcs.Agent.Runner.submit(
                 project,
                 thread["id"],
                 "Exhaust model stream retries",
                 [],
                 %{}
               )

      assert_receive {:http_request, first_request}, 1_000
      assert_receive {:http_request, second_request}, 1_000
      assert first_request.path == "/v1/chat/completions"
      assert second_request.path == "/v1/chat/completions"

      wait_until(fn ->
        {:ok, turns} = Avcs.Turns.list_turns(project, thread["id"])
        Enum.any?(turns, &(&1["id"] == created["turn"]["id"] and &1["status"] == "failed"))
      end)

      {:ok, items} = Avcs.Turns.list_items(project, thread["id"])

      assert Enum.any?(
               items,
               &(&1["type"] == "error" and String.contains?(&1["content"], "timeout"))
             )
    after
      HTTPTestServer.stop(server)
    end
  end

  test "AvcsAgent image_gen runs through controlled registry and broadcasts tool lifecycle", %{
    project: project
  } do
    Application.put_env(:avcs, :agent_harness, Avcs.Agent.Harness.AvcsAgent)
    Application.put_env(:avcs, :avcs_agent_client, AvcsAgentImageToolClient)
    Application.put_env(:avcs, :agent_runner_test_pid, self())
    Phoenix.PubSub.subscribe(Avcs.PubSub, "avcs:lobby")

    {:ok, thread} = Avcs.Threads.create_thread(project, "AvcsAgent image tool")

    assert {:ok, created} =
             Avcs.Agent.Runner.submit(project, thread["id"], "Generate an image", [], %{})

    assert_receive {:avcs_agent_image_tool_call, 1, tools}, 1_000
    assert tool_names(tools) == ~w(image_gen read ls find grep bash)

    assert_receive {:avcs_agent_generate_image, "A precise Avcs test image", image_opts}, 1_000
    assert Keyword.get(image_opts, :count) == 1

    assert_receive %Phoenix.Socket.Broadcast{
                     event: "tool:updated",
                     payload: %{status: "started"}
                   },
                   1_000

    assert_receive %Phoenix.Socket.Broadcast{
                     event: "tool:updated",
                     payload: %{status: "updated", progress_status: "updated"}
                   },
                   1_000

    assert_receive %Phoenix.Socket.Broadcast{
                     event: "tool:updated",
                     payload: %{status: "completed"}
                   },
                   1_000

    assert_receive %Phoenix.Socket.Broadcast{
                     event: "board:item:created",
                     payload: %{item: board_item}
                   },
                   1_000

    assert board_item["asset_id"]

    wait_until(fn ->
      {:ok, turns} = Avcs.Turns.list_turns(project, thread["id"])
      Enum.any?(turns, &(&1["id"] == created["turn"]["id"] and &1["status"] == "completed"))
    end)

    {:ok, assets} = Avcs.Assets.list_assets(project)
    assert [%{"relative_path" => "output/" <> _rest, "source" => "generated"}] = assets

    {:ok, board_items} = Avcs.Board.list_items(project)
    assert [%{"asset_id" => asset_id}] = board_items
    assert asset_id == hd(assets)["id"]

    {:ok, items} = Avcs.Turns.list_items(project, thread["id"])
    assert Enum.any?(items, &(&1["type"] == "image_asset"))

    assert Enum.any?(
             items,
             &(&1["remote_item_id"] == "tool-image-1" and &1["type"] == "tool_result")
           )

    {:ok, events} = Avcs.Trace.list_events(project, thread["id"], turn_id: created["turn"]["id"])

    assert Enum.any?(events, fn event ->
             event["event_name"] == "state_snapshot" and
               event["status"] == "tool_call_completed" and
               get_in(event, ["payload", "pending_tool_calls"]) == []
           end)
  end

  test "AvcsAgent image_gen sends reference assets to image client", %{project: project} do
    Application.put_env(:avcs, :agent_harness, Avcs.Agent.Harness.AvcsAgent)
    Application.put_env(:avcs, :avcs_agent_client, AvcsAgentImageReferenceClient)
    Application.put_env(:avcs, :agent_runner_test_pid, self())

    {:ok, previous_image_model} = Avcs.SiteSettings.get_setting("agent.avcs_agent.image_model")

    {:ok, _settings} =
      Avcs.SiteSettings.update_settings(%{
        "agent.avcs_agent.image_model" => "google/gemini-3-pro-image"
      })

    reference_path = Path.join([project["folder_path"], "work", "reference-source.png"])
    File.write!(reference_path, test_png_alt())
    {:ok, asset} = Avcs.Assets.upsert_asset(project, reference_path, source: "import")
    Application.put_env(:avcs, :agent_runner_reference_asset_id, asset["id"])

    mask_path = Path.join([project["folder_path"], "work", "reference-mask.png"])
    File.write!(mask_path, test_png())
    {:ok, mask_asset} = Avcs.Assets.upsert_asset(project, mask_path, source: "mask")
    Application.put_env(:avcs, :agent_runner_reference_mask_asset_id, mask_asset["id"])

    on_exit(fn ->
      Avcs.SiteSettings.update_settings(%{"agent.avcs_agent.image_model" => previous_image_model})
      Application.delete_env(:avcs, :agent_runner_reference_asset_id)
      Application.delete_env(:avcs, :agent_runner_reference_mask_asset_id)
    end)

    {:ok, thread} = Avcs.Threads.create_thread(project, "AvcsAgent reference image tool")

    assert {:ok, created} =
             Avcs.Agent.Runner.submit(project, thread["id"], "Generate from a reference", [], %{})

    assert_receive {:avcs_agent_reference_image_call, 1, tools}, 1_000
    assert tool_names(tools) == ~w(image_gen read ls find grep bash)

    assert_receive {:avcs_agent_reference_generate_image, prompt, reference_images, mask_image,
                    image_opts},
                   1_000

    assert prompt =~ "referenced asset"
    assert Keyword.get(image_opts, :count) == 1
    assert Keyword.get(image_opts, :size) == "1024x1024"
    assert Keyword.get(image_opts, :quality) == "high"
    assert Keyword.get(image_opts, :output_format) == "jpeg"
    assert Keyword.get(image_opts, :output_compression) == 80
    assert Keyword.get(image_opts, :background) == "opaque"
    assert Keyword.get(image_opts, :moderation) == "low"

    assert [
             %{
               asset_id: asset_id,
               path: ^reference_path,
               relative_path: "work/reference-source.png",
               file_name: "reference-source.png",
               mime_type: "image/png"
             }
           ] = reference_images

    assert asset_id == asset["id"]

    assert %{
             asset_id: mask_asset_id,
             path: ^mask_path,
             relative_path: "work/reference-mask.png",
             file_name: "reference-mask.png",
             mime_type: "image/png"
           } = mask_image

    assert mask_asset_id == mask_asset["id"]

    wait_until(fn ->
      {:ok, turns} = Avcs.Turns.list_turns(project, thread["id"])
      Enum.any?(turns, &(&1["id"] == created["turn"]["id"] and &1["status"] == "completed"))
    end)

    {:ok, items} = Avcs.Turns.list_items(project, thread["id"])

    assert tool_result =
             Enum.find(
               items,
               &(&1["remote_item_id"] == "tool-image-reference-1" and
                   &1["type"] == "tool_result")
             )

    result = tool_result["payload"]["remote_item"]["result"]
    assert result["reference_count"] == 1
    assert result["mask_asset_id"] == mask_asset["id"]
    assert result["request"]["size"] == "1024x1024"
    assert result["request"]["quality"] == "high"
    assert result["request"]["output_format"] == "jpeg"
    assert result["request"]["output_compression"] == 80
    refute Map.has_key?(result, "unsupported")

    {:ok, events} = Avcs.Trace.list_events(project, thread["id"], turn_id: created["turn"]["id"])

    assert Enum.any?(events, fn event ->
             event["event_name"] == "postToolUse" and
               get_in(event, ["payload", "result", "reference_count"]) == 1
           end)
  end

  test "AvcsAgent completes image turn when only the final text response times out", %{
    project: project
  } do
    Application.put_env(:avcs, :agent_harness, Avcs.Agent.Harness.AvcsAgent)
    Application.put_env(:avcs, :avcs_agent_client, AvcsAgentImageFinalTimeoutClient)
    Application.put_env(:avcs, :agent_runner_test_pid, self())

    {:ok, thread} = Avcs.Threads.create_thread(project, "AvcsAgent image final timeout")

    assert {:ok, created} =
             Avcs.Agent.Runner.submit(project, thread["id"], "Generate an image", [], %{})

    assert_receive {:avcs_agent_image_timeout_call, 1, _tools}, 1_000

    assert_receive {:avcs_agent_timeout_generate_image, "A timeout regression test image",
                    image_opts},
                   1_000

    assert Keyword.get(image_opts, :count) == 1
    assert_receive {:avcs_agent_image_timeout_call, 2, _tools}, 1_000

    wait_until(fn ->
      {:ok, turns} = Avcs.Turns.list_turns(project, thread["id"])
      Enum.any?(turns, &(&1["id"] == created["turn"]["id"] and &1["status"] == "completed"))
    end)

    {:ok, assets} = Avcs.Assets.list_assets(project)
    assert [%{"relative_path" => "output/" <> _rest, "source" => "generated"}] = assets

    {:ok, items} = Avcs.Turns.list_items(project, thread["id"])
    assert Enum.any?(items, &(&1["type"] == "image_asset"))
    refute Enum.any?(items, &(&1["type"] == "error"))

    assert assistant = Enum.find(items, &(&1["type"] == "assistant_message"))
    assert assistant["content"] =~ "最终文字回复超时"
    assert assistant["content"] =~ "output/"

    {:ok, events} = Avcs.Trace.list_events(project, thread["id"], turn_id: created["turn"]["id"])

    assert Enum.any?(events, fn event ->
             event["event_name"] == "final_response_timeout" and event["status"] == "completed"
           end)
  end

  test "AvcsAgent APOD provider runs bash then image_gen without manual script execution", %{
    project: project
  } do
    Application.put_env(:avcs, :agent_harness, Avcs.Agent.Harness.AvcsAgent)
    Application.put_env(:avcs, :avcs_agent_client, AvcsAgentApodWorkflowClient)
    Application.put_env(:avcs, :agent_runner_test_pid, self())

    Application.put_env(:avcs, :data_provider_scripts, %{
      "avcs-data-prodiver-apod" => fake_apod_script!(project)
    })

    {:ok, thread} = Avcs.Threads.create_thread(project, "AvcsAgent APOD provider")

    data_provider = %{
      "slug" => "avcs-data-prodiver-apod",
      "name" => "NASA APOD",
      "version" => "0.1.0",
      "loaded" => true
    }

    assert {:ok, created} =
             Avcs.Agent.Runner.submit(
               project,
               thread["id"],
               "Create an APOD poster",
               [],
               %{data_provider: data_provider}
             )

    assert_receive {:avcs_agent_apod_workflow_call, 1, first_messages, tool_names}, 1_000
    assert tool_names == ~w(image_gen read ls find grep bash)
    refute messages_contain?(first_messages, "Read and follow the data provider skill")
    refute messages_contain?(first_messages, "_build/dev/lib/avcs/priv/skills")
    assert messages_contain?(first_messages, "Follow the injected data provider skill context")
    assert messages_contain?(first_messages, "avcs-imagegen-avcs-agent")
    refute messages_contain?(first_messages, "avcs-imagegen-codex")

    assert_receive {:avcs_agent_apod_workflow_call, 2, messages, _tool_names}, 1_000
    assert Enum.any?(messages, &(to_string(&1["content"]) =~ "Fake APOD"))

    assert_receive {:avcs_agent_apod_generate_image, prompt, image_opts}, 1_000
    assert prompt =~ "Fake APOD"
    assert Keyword.get(image_opts, :reference_images) == []

    wait_until(fn ->
      {:ok, turns} = Avcs.Turns.list_turns(project, thread["id"])
      Enum.any?(turns, &(&1["id"] == created["turn"]["id"] and &1["status"] == "completed"))
    end)

    {:ok, assets} = Avcs.Assets.list_assets(project)

    assert Enum.any?(
             assets,
             &(&1["source"] == "provider" and String.starts_with?(&1["relative_path"], "work/"))
           )

    assert Enum.any?(
             assets,
             &(&1["source"] == "generated" and String.starts_with?(&1["relative_path"], "output/"))
           )

    {:ok, board_items} = Avcs.Board.list_items(project)
    assert length(board_items) == 1

    {:ok, items} = Avcs.Turns.list_items(project, thread["id"])

    assert Enum.any?(
             items,
             &(&1["remote_item_id"] == "tool-apod-1" and &1["type"] == "tool_result")
           )

    assert Enum.any?(
             items,
             &(&1["remote_item_id"] == "tool-image-after-apod" and &1["type"] == "tool_result")
           )

    assert Enum.any?(items, &(&1["type"] == "image_asset"))

    assert assistant = Enum.find(items, &(&1["type"] == "assistant_message"))
    assert assistant["payload"]["provider_context"]["result"]["title"] == "Fake APOD"
  end

  test "AvcsAgent sends referenced images as structured model input and broadcasts snapshots", %{
    project: project
  } do
    Application.put_env(:avcs, :agent_harness, Avcs.Agent.Harness.AvcsAgent)
    Application.put_env(:avcs, :avcs_agent_client, AvcsAgentVisionClient)
    Application.put_env(:avcs, :agent_runner_test_pid, self())
    Phoenix.PubSub.subscribe(Avcs.PubSub, "avcs:lobby")

    {:ok, thread} = Avcs.Threads.create_thread(project, "AvcsAgent vision")
    reference_path = Path.join([project["folder_path"], "work", "reference.png"])
    File.write!(reference_path, test_png())
    {:ok, asset} = Avcs.Assets.upsert_asset(project, reference_path, source: "import")

    assert {:ok, created} =
             Avcs.Agent.Runner.submit(
               project,
               thread["id"],
               "Use the referenced image",
               [asset["id"]],
               %{}
             )

    assert_receive {:avcs_agent_vision_call, messages, tools}, 1_000
    assert tool_names(tools) == ~w(image_gen read ls find grep bash)

    assert %{"content" => content, "reference_assets" => [ref]} = List.last(messages)
    assert is_list(content)
    assert Enum.any?(content, &(&1["type"] == "text" and &1["text"] =~ "Use the referenced"))

    assert Enum.any?(
             content,
             &(&1["type"] == "image_url" and
                 String.starts_with?(&1["image_url"]["url"], "data:image/png;base64,"))
           )

    assert ref["asset_id"] == asset["id"]
    assert ref["relative_path"] == "work/reference.png"

    assert_receive %Phoenix.Socket.Broadcast{
                     event: "agent:state_snapshot",
                     payload: %{snapshot: %{phase: "starting"}}
                   },
                   1_000

    wait_until(fn ->
      {:ok, turns} = Avcs.Turns.list_turns(project, thread["id"])
      Enum.any?(turns, &(&1["id"] == created["turn"]["id"] and &1["status"] == "completed"))
    end)

    {:ok, events} = Avcs.Trace.list_events(project, thread["id"], turn_id: created["turn"]["id"])
    assert Enum.any?(events, &(&1["event_name"] == "context_transform"))
    assert Enum.any?(events, &(&1["event_name"] == "state_snapshot"))
  end

  test "AvcsAgent context compaction uses token budget and preserves recent context" do
    messages =
      [
        %{"role" => "system", "content" => "System instructions"}
        | Enum.map(1..30, fn index ->
            %{
              "role" => if(rem(index, 2) == 0, do: "assistant", else: "user"),
              "content" => String.duplicate("message #{index} ", 80)
            }
          end)
      ]

    assert {:ok, compacted, meta} =
             Avcs.Agent.ContextCompaction.compact(messages, 0.25, context_token_budget: 300)

    assert meta.compacted == true
    assert meta.summarized_messages > 0
    assert hd(compacted)["role"] == "system"
    assert Enum.any?(compacted, &(&1["avcs_kind"] == "context_compaction"))
    assert List.last(compacted)["content"] =~ "message 30"
  end

  test "AvcsAgent active tools stay inside the controlled registry" do
    assert [] = Avcs.Agent.Tools.Registry.schemas(%{active_tools: []})

    assert ~w(image_gen read ls find grep bash) =
             Avcs.Agent.Tools.Registry.schemas()
             |> tool_names()

    assert ~w(image_gen bash) =
             Avcs.Agent.Tools.Registry.schemas(%{active_tools: ["image_gen", "bash"]})
             |> tool_names()

    assert {:error, result} =
             Avcs.Agent.Tools.Registry.execute(
               %{"id" => "bad-tool", "name" => "bash", "arguments" => "{}"},
               %{},
               active_tools: ["image_gen", "bash"]
             )

    assert result["status"] == "failed"
    assert result["error"]["code"] == "command_not_allowed"

    assert {:error, result} =
             Avcs.Agent.Tools.Registry.execute(
               %{"id" => "write-1", "name" => "write", "arguments" => "{}"},
               %{},
               active_tools: Avcs.Agent.Tools.Registry.default_active_tools()
             )

    assert result["status"] == "failed"
    assert result["error"]["code"] == "tool_not_allowed"
  end

  test "AvcsAgent built-in skill loading is limited to bundled skill files" do
    assert [%{"name" => "avcs-imagegen-avcs-agent", "path" => path, "content" => content}] =
             Avcs.Agent.BuiltinSkillLoader.load("avcs-imagegen-avcs-agent")

    assert String.contains?(path, "/priv/skills/avcs-imagegen-avcs-agent/SKILL.md")
    assert content =~ "Avcs 后端 `image_gen` tool"

    assert [%{"name" => "avcs-imagegen-codex", "path" => codex_path, "content" => codex}] =
             Avcs.Agent.BuiltinSkillLoader.load("avcs-imagegen-codex")

    assert String.contains?(codex_path, "/priv/skills/avcs-imagegen-codex/SKILL.md")
    assert codex =~ "Codex built-in `image_gen`"
    assert [] = Avcs.Agent.BuiltinSkillLoader.load("avcs-imagegen")
    assert [] = Avcs.Agent.BuiltinSkillLoader.load("../outside")
  end

  test "AvcsAgent records local thread/fork and thread/rollback semantics", %{project: project} do
    {:ok, thread} = Avcs.Threads.create_thread(project, "AvcsAgent local branch")
    {:ok, created} = Avcs.Turns.create_user_turn(project, thread["id"], "Original prompt", [])

    assert {:ok, %{remote_thread_id: forked_thread_id}} =
             Avcs.Agent.Harness.AvcsAgent.prepare_rerun(
               project,
               thread["id"],
               created["turn"]["id"],
               "avcs-agent-thread-old",
               2,
               %{model: "ignored-codex-model", approval_policy: "on-request"}
             )

    assert String.starts_with?(forked_thread_id, "avcs-agent-thread-")

    {:ok, events} = Avcs.Trace.list_events(project, thread["id"], turn_id: created["turn"]["id"])
    assert fork = Enum.find(events, &(&1["event_name"] == "thread/fork"))
    assert rollback = Enum.find(events, &(&1["event_name"] == "thread/rollback"))
    assert fork["payload"]["current_thread_path"] == "local_sqlite"
    assert fork["payload"]["branch_summary"]["rollback_turn_count"] == 2
    assert rollback["payload"]["rollback_turn_count"] == 2
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
    assert synced["remote_thread_id"] == "codex-thread-1"
    assert synced["title"] == "Generated logo concepts"

    {:ok, items} = Avcs.Turns.list_items(project, thread["id"])
    assert Enum.any?(items, &(&1["role"] == "assistant" and &1["content"] == "Done"))

    assert tool_item =
             Enum.find(items, &(&1["remote_item_id"] == "tool-1" and &1["type"] == "tool_result"))

    assert tool_item["status"] == "completed"
    assert tool_item["content"] == "echo render"
    assert tool_item["payload"]["tool_name"] == "command"

    assert approval_item =
             Enum.find(
               items,
               &(&1["remote_item_id"] == "review-1" and &1["type"] == "approval_request")
             )

    assert approval_item["status"] == "denied"
    assert approval_item["content"] == "echo render"
    assert approval_item["payload"]["review_id"] == "review-1"
    assert approval_item["payload"]["target_item_id"] == "tool-1"
    assert approval_item["payload"]["event"]["action"]["type"] == "command"
  end

  test "marks interrupted turns without creating an error item", %{project: project} do
    Application.put_env(:avcs, :agent_harness, InterruptedHarness)

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
    Application.put_env(:avcs, :agent_harness, MaskInstructionHarness)
    Application.put_env(:avcs, :agent_runner_test_pid, self())

    {:ok, thread} = Avcs.Threads.create_thread(project, "Mask edit thread")
    base_path = Path.join([project["folder_path"], "output", "base.png"])
    mask_path = Path.join([project["folder_path"], ".avcs", "cache", "temp", "masks", "mask.png"])
    File.mkdir_p!(Path.dirname(mask_path))
    File.write!(base_path, test_png_alt())
    File.write!(mask_path, test_png())
    {:ok, base_asset} = Avcs.Assets.upsert_asset(project, base_path, source: "generated")
    {:ok, mask_asset} = Avcs.Assets.upsert_asset(project, mask_path, source: "mask")

    mask_edit = %{
      "mode" => "visual_reference",
      "base_asset_id" => base_asset["id"],
      "mask_asset_id" => mask_asset["id"],
      "mask_semantics" => "transparent_edit_opaque_keep"
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
    assert text =~ "marked or transparent-alpha areas indicate the region to change"
    assert reference_paths == [base_path, mask_path]
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 1_000
  end

  test "adds data provider instructions and persists provider context", %{project: project} do
    Application.put_env(:avcs, :agent_harness, DataProviderInstructionHarness)
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
    assert text =~ "AvcsAgent `bash` tool"
    assert text =~ ~s("command_kind":"data_provider")
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
             Enum.find(
               items,
               &(&1["remote_item_id"] == "image-1" and &1["type"] == "tool_result")
             )

    assert image_item["status"] == "completed"
    assert image_item["payload"]["tool_name"] == "image generation"
    assert image_item["payload"]["remote_item"]["savedPath"] == "/tmp/fake-image.png"
    refute Map.has_key?(image_item["payload"]["remote_item"], "result")
    assert image_item["payload"]["remote_item"]["result_omitted"] == true
    assert image_item["payload"]["remote_item"]["result_size_bytes"] == 150_000

    assert assistant_item =
             Enum.find(items, &(&1["type"] == "assistant_message" and &1["content"] == "Done"))

    assert assistant_image =
             Enum.find(
               assistant_item["payload"]["remote_items"],
               &(&1["id"] == "image-1" and &1["type"] == "imageGeneration")
             )

    refute Map.has_key?(assistant_image, "result")
    assert assistant_image["result_omitted"] == true
    assert assistant_image["result_size_bytes"] == 150_000
  end

  test "repair_thread reconciles Codex thread/read turns into local state", %{project: project} do
    File.write!(ThreadNameHarness.recovered_image_path(), test_png())
    on_exit(fn -> File.rm(ThreadNameHarness.recovered_image_path()) end)

    {:ok, thread} = Avcs.Threads.create_thread(project, "Broken image thread")
    {:ok, :ok} = Avcs.Threads.set_remote_thread_id(project, thread["id"], "codex-thread-1")
    {:ok, created} = Avcs.Turns.create_user_turn(project, thread["id"], "Make an image", [])

    {:ok, _running_image} =
      Avcs.Turns.upsert_remote_item(project,
        turn_id: created["turn"]["id"],
        thread_id: thread["id"],
        remote_item_id: "image-1",
        type: "tool_call",
        role: "tool",
        content: "Image generation",
        status: "running",
        payload: %{
          tool_name: "image generation",
          remote_item: %{
            "id" => "image-1",
            "type" => "imageGeneration",
            "status" => "in_progress"
          }
        }
      )

    assert {:ok, repair} = Avcs.Agent.Runner.repair_thread(project, thread["id"])
    assert repair.matched_turns == 1
    assert repair.synced_items == 3
    assert repair.imported_images == 1

    {:ok, [turn]} = Avcs.Turns.list_turns(project, thread["id"])
    assert turn["remote_turn_id"] == "codex-turn-1"
    assert turn["status"] == "completed"

    {:ok, items} = Avcs.Turns.list_items(project, thread["id"])

    assert image_item =
             Enum.find(
               items,
               &(&1["remote_item_id"] == "image-1" and &1["type"] == "tool_result")
             )

    assert image_item["status"] == "completed"
    assert image_item["payload"]["recovered"] == true

    assert image_item["payload"]["remote_item"]["savedPath"] ==
             ThreadNameHarness.recovered_image_path()

    refute Map.has_key?(image_item["payload"]["remote_item"], "result")

    assert Enum.any?(
             items,
             &(&1["remote_item_id"] == "agent-1" and &1["type"] == "assistant_message")
           )

    assert Enum.any?(items, &(&1["type"] == "image_asset"))

    {:ok, [asset]} = Avcs.Assets.list_assets(project)
    assert asset["source"] == "generated"
    assert String.starts_with?(asset["relative_path"], "output/")
  end

  test "repair_thread recovers missing Codex thread id from matching session rollout", %{
    project: project
  } do
    File.write!(ThreadNameHarness.recovered_image_path(), test_png())
    on_exit(fn -> File.rm(ThreadNameHarness.recovered_image_path()) end)

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
      Avcs.Turns.upsert_remote_item(project,
        turn_id: created["turn"]["id"],
        thread_id: thread["id"],
        remote_item_id: "image-1",
        type: "tool_call",
        role: "tool",
        content: "Image generation",
        status: "running",
        payload: %{
          tool_name: "image generation",
          remote_item: %{
            "id" => "image-1",
            "type" => "imageGeneration",
            "status" => "in_progress"
          }
        }
      )

    assert {:ok, repair} = Avcs.Agent.Runner.repair_thread(project, thread["id"])
    assert repair.remote_thread_id == "codex-thread-1"
    assert repair.matched_turns == 1

    {:ok, synced} = Avcs.Threads.get_thread(project, thread["id"])
    assert synced["remote_thread_id"] == "codex-thread-1"
  end

  test "rerun_from_item forks and rolls back Codex thread before restarting edited turn", %{
    project: project
  } do
    Application.put_env(:avcs, :agent_harness, EditRerunHarness)
    Application.put_env(:avcs, :agent_runner_test_pid, self())

    {:ok, thread} = Avcs.Threads.create_thread(project, "Edit rerun")

    assert {:ok, :ok} =
             Avcs.Threads.set_remote_thread_id(project, thread["id"], "codex-thread-old")

    {:ok, first} = Avcs.Turns.create_user_turn(project, thread["id"], "Original prompt", [])
    {:ok, _turn} = Avcs.Turns.complete_turn(project, first["turn"]["id"], "codex-turn-old-1")
    set_turn_time(project, first["turn"]["id"], 1)

    {:ok, second} = Avcs.Turns.create_user_turn(project, thread["id"], "Later prompt", [])
    {:ok, _turn} = Avcs.Turns.complete_turn(project, second["turn"]["id"], "codex-turn-old-2")
    set_turn_time(project, second["turn"]["id"], 2)

    assert {:ok, edited} =
             Avcs.Agent.Runner.rerun_from_item(project, first["item"]["id"], "Revised prompt")

    assert edited["turn"]["id"] == first["turn"]["id"]
    assert edited["invalidated_turn_ids"] == [second["turn"]["id"]]

    assert_receive {:fork_thread, "codex-thread-old"}, 1_000
    assert_receive {:rollback_thread, "codex-thread-forked", 2}, 1_000
    assert_receive {:rerun_turn, "codex-thread-forked", "Revised prompt"}, 1_000

    wait_until(fn ->
      {:ok, items} = Avcs.Turns.list_items(project, thread["id"])
      Enum.any?(items, &(&1["type"] == "assistant_message" and &1["content"] == "Rerun done"))
    end)

    {:ok, synced} = Avcs.Threads.get_thread(project, thread["id"])
    assert synced["remote_thread_id"] == "codex-thread-forked"

    {:ok, turns} = Avcs.Turns.list_turns(project, thread["id"])
    assert Enum.map(turns, & &1["id"]) == [first["turn"]["id"]]
    assert hd(turns)["remote_turn_id"] == "codex-rerun-turn"
    assert hd(turns)["status"] == "completed"
  end

  test "persists Codex thread id from turn_started before run completion", %{project: project} do
    Application.put_env(:avcs, :agent_harness, TurnStartedHarness)

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
    assert synced["remote_thread_id"] == "codex-thread-from-turn-start"

    {:ok, [turn]} = Avcs.Turns.list_turns(project, thread["id"])
    assert turn["remote_turn_id"] == "codex-turn-from-start"
    assert turn["status"] == "failed"
  end

  test "persists Codex thread id from item notification when thread is still unlinked", %{
    project: project
  } do
    Application.put_env(:avcs, :agent_harness, ItemNotificationHarness)

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
    assert synced["remote_thread_id"] == "codex-thread-from-item"

    {:ok, items} = Avcs.Turns.list_items(project, thread["id"])

    assert Enum.any?(
             items,
             &(&1["remote_item_id"] == "tool-from-item" and &1["type"] == "tool_call")
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
  end

  defp tool_names(tools) do
    Enum.map(tools, &get_in(&1, ["function", "name"]))
  end

  defp runner_text_stream(text) do
    [
      HTTPTestServer.sse_chunk(%{
        "id" => "avcs-agent-runner-retry-turn",
        "model" => "fake-text-model",
        "choices" => [
          %{
            "delta" => %{
              "content" => text
            }
          }
        ]
      }),
      HTTPTestServer.sse_done()
    ]
  end

  defp configure_actual_avcs_agent_runtime(port) do
    previous =
      Enum.map(
        [
          "agent.avcs_agent.base_url",
          "agent.avcs_agent.text_model",
          "providers.vercel_ai_gateway.api_key"
        ],
        &previous_site_setting/1
      )

    on_exit(fn -> restore_site_settings(previous) end)

    {:ok, _settings} =
      Avcs.SiteSettings.update_settings(%{
        "agent.avcs_agent.base_url" => "http://127.0.0.1:#{port}/v1",
        "agent.avcs_agent.text_model" => "fake-text-model",
        "providers.vercel_ai_gateway.api_key" => "test-key"
      })

    :ok
  end

  defp previous_site_setting("providers.vercel_ai_gateway.api_key" = key) do
    {:ok, value} = Avcs.SiteSettings.secret_value(key)
    {key, value}
  end

  defp previous_site_setting(key) do
    {:ok, value} = Avcs.SiteSettings.get_setting(key)
    {key, value}
  end

  defp restore_site_settings(settings) do
    Enum.each(settings, fn
      {key, nil} ->
        Avcs.SiteSettings.reset_setting(key)

      {key, value} ->
        Avcs.SiteSettings.update_settings(%{key => value})
    end)
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:avcs, key)
  defp restore_app_env(key, value), do: Application.put_env(:avcs, key, value)

  defp messages_contain?(messages, text) do
    Enum.any?(messages, fn message ->
      message
      |> Map.get("content")
      |> content_to_string()
      |> String.contains?(text)
    end)
  end

  defp content_to_string(content) when is_binary(content), do: content
  defp content_to_string(content), do: inspect(content)

  defp fake_apod_script!(project) do
    script_path = Path.join(project["folder_path"], "work/fake_fetch_apod.py")

    File.write!(script_path, """
    import argparse, base64, json
    from pathlib import Path

    parser = argparse.ArgumentParser()
    parser.add_argument("--out-dir", required=True)
    parser.add_argument("--date")
    parser.add_argument("--prefer-hd", action="store_true")
    args = parser.parse_args()

    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    image_path = out_dir / "fake-apod.png"
    image_path.write_bytes(base64.b64decode("#{Base.encode64(test_png())}"))

    print(json.dumps({
      "status": "success",
      "data": {
        "date": args.date or "2026-06-01",
        "title": "Fake APOD",
        "explanation": "A fake APOD payload for integration tests.",
        "copyright": "Avcs",
        "media_type": "image",
        "source": "fake",
        "apod_url": "https://example.test/apod",
        "image_path": str(image_path)
      }
    }))
    """)

    script_path
  end

  defp wait_until(fun) do
    deadline = System.monotonic_time(:millisecond) + 1_000
    do_wait_until(fun, deadline)
  end

  defp do_wait_until(fun, deadline) do
    if fun.() do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        flunk("condition was not met before timeout")
      else
        Process.sleep(10)
        do_wait_until(fun, deadline)
      end
    end
  end
end
