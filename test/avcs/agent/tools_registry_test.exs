defmodule Avcs.Agent.Tools.RegistryTest do
  use ExUnit.Case, async: false

  alias Avcs.Agent.Tools.ProjectFile

  defmodule ImageGenCaptureClient do
    @png_base64 "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII="

    def generate_image(prompt, opts) do
      if pid = Application.get_env(:avcs, :image_gen_capture_pid) do
        send(pid, {:image_gen_capture, prompt, opts})
      end

      {:ok,
       %{
         model: Keyword.get(opts, :model) || "fake-image-model",
         images: [%{base64: @png_base64, mime_type: "image/png"}],
         raw_id: "fake-image-response"
       }}
    end
  end

  setup do
    previous_scripts = Application.get_env(:avcs, :data_provider_scripts)
    previous_timeout = Application.get_env(:avcs, :data_provider_timeout_ms)
    previous_avcs_agent_client = Application.get_env(:avcs, :avcs_agent_client)
    previous_image_gen_capture_pid = Application.get_env(:avcs, :image_gen_capture_pid)

    project_dir =
      Path.join(System.tmp_dir!(), "avcs-tools-#{System.unique_integer([:positive])}")

    File.rm_rf!(project_dir)
    {:ok, project} = Avcs.Projects.open_project(project_dir)
    {:ok, thread} = Avcs.Threads.create_thread(project, "Tool registry")
    {:ok, created} = Avcs.Turns.create_user_turn(project, thread["id"], "Use tools", [])

    context = %{
      project: project,
      thread_id: thread["id"],
      turn_id: created["turn"]["id"],
      remote_thread_id: "remote-thread",
      remote_turn_id: "remote-turn",
      tool_call_id: "tool-test",
      model: "test-model"
    }

    on_exit(fn ->
      if previous_scripts do
        Application.put_env(:avcs, :data_provider_scripts, previous_scripts)
      else
        Application.delete_env(:avcs, :data_provider_scripts)
      end

      if previous_timeout do
        Application.put_env(:avcs, :data_provider_timeout_ms, previous_timeout)
      else
        Application.delete_env(:avcs, :data_provider_timeout_ms)
      end

      if previous_avcs_agent_client do
        Application.put_env(:avcs, :avcs_agent_client, previous_avcs_agent_client)
      else
        Application.delete_env(:avcs, :avcs_agent_client)
      end

      if previous_image_gen_capture_pid do
        Application.put_env(:avcs, :image_gen_capture_pid, previous_image_gen_capture_pid)
      else
        Application.delete_env(:avcs, :image_gen_capture_pid)
      end

      File.rm_rf!(project_dir)
    end)

    %{project: project, thread: thread, turn: created["turn"], context: context}
  end

  test "read enforces project boundaries and records lifecycle trace", %{
    project: project,
    thread: thread,
    turn: turn,
    context: context
  } do
    File.write!(Path.join([project["folder_path"], "work", "notes.txt"]), "one\ntwo\nthree")

    assert {:ok, result} =
             execute(
               "read",
               %{"path" => "work/notes.txt", "offset" => 1, "limit" => 1},
               context
             )

    assert result["content"] == "two"
    assert result["relative_path"] == "work/notes.txt"
    assert result["truncated"] == true

    assert {:error, failed} = execute("read", %{"path" => "../outside.txt"}, context)
    assert failed["error"]["code"] == "outside_project"

    File.write!(Path.join([project["folder_path"], ".avcs", "hidden.txt"]), "hidden")
    assert {:error, failed} = execute("read", %{"path" => ".avcs/hidden.txt"}, context)
    assert failed["error"]["code"] == "path_denied"

    outside = Path.join(System.tmp_dir!(), "avcs-tools-outside.txt")
    File.write!(outside, "outside")
    symlink = Path.join([project["folder_path"], "work", "escape.txt"])
    File.ln_s!(outside, symlink)
    assert {:error, failed} = execute("read", %{"path" => "work/escape.txt"}, context)
    assert failed["error"]["code"] == "symlink_denied"

    File.write!(Path.join([project["folder_path"], "work", "binary.dat"]), <<0, 1, 2, 3>>)
    assert {:error, failed} = execute("read", %{"path" => "work/binary.dat"}, context)
    assert failed["error"]["code"] == "binary_file"

    large_path = Path.join([project["folder_path"], "work", "large.txt"])
    File.write!(large_path, String.duplicate("a", ProjectFile.max_text_file_bytes() + 1))
    assert {:error, failed} = execute("read", %{"path" => "work/large.txt"}, context)
    assert failed["error"]["code"] == "file_too_large"

    {:ok, events} = Avcs.Trace.list_events(project, thread["id"], turn_id: turn["id"])
    assert Enum.any?(events, &tool_event?(&1, "preToolUse", "read", "completed"))
    assert Enum.any?(events, &tool_event?(&1, "postToolUse", "read", "completed"))
  end

  test "ls find and grep search internally without scanning denied paths", %{
    project: project,
    context: context
  } do
    File.mkdir_p!(Path.join([project["folder_path"], "work", "sub"]))
    File.write!(Path.join([project["folder_path"], "work", "a.txt"]), "alpha\nneedle\nomega")
    File.write!(Path.join([project["folder_path"], "work", "sub", "b.md"]), "needle in markdown")
    File.write!(Path.join([project["folder_path"], ".avcs", "hidden.txt"]), "needle hidden")

    outside_dir = Path.join(System.tmp_dir!(), "avcs-tools-outside-dir")
    File.rm_rf!(outside_dir)
    File.mkdir_p!(outside_dir)
    File.write!(Path.join(outside_dir, "outside.txt"), "needle outside")
    File.ln_s!(outside_dir, Path.join([project["folder_path"], "work", "outside-link"]))

    assert {:ok, result} = execute("ls", %{"path" => ".", "recursive" => true}, context)
    relative_paths = Enum.map(result["entries"], & &1["relative_path"])
    assert "work/a.txt" in relative_paths
    assert "work/sub/b.md" in relative_paths
    refute ".avcs/hidden.txt" in relative_paths
    refute "work/outside-link/outside.txt" in relative_paths

    assert {:ok, result} = execute("find", %{"path" => ".", "pattern" => "**/*.md"}, context)
    assert [%{"relative_path" => "work/sub/b.md"}] = result["files"]

    assert {:ok, result} =
             execute(
               "grep",
               %{
                 "path" => ".",
                 "pattern" => "needle",
                 "glob" => "**/*.txt",
                 "context_lines" => 1
               },
               context
             )

    assert [%{"relative_path" => "work/a.txt", "line_number" => 2} = match] =
             result["matches"]

    assert match["before"] == ["alpha"]
    assert match["after"] == ["omega"]

    assert {:error, failed} = execute("ls", %{"path" => ".avcs"}, context)
    assert failed["error"]["code"] == "path_denied"

    assert_tool_traced(project, context, "ls")
    assert_tool_traced(project, context, "find")
    assert_tool_traced(project, context, "grep")
  end

  test "write and edit are opt-in and enforce scoped writes", %{
    project: project,
    context: context
  } do
    assert {:error, failed} =
             execute("write", %{"path" => "work/new.txt", "content" => "x"}, context)

    assert failed["error"]["code"] == "tool_not_allowed"

    assert {:error, failed} = execute("edit", %{"path" => "work/new.txt"}, context)
    assert failed["error"]["code"] == "tool_not_allowed"

    assert {:ok, result} =
             execute(
               "write",
               %{"path" => "work/new.txt", "content" => "hello old"},
               context,
               active_tools: ["write"]
             )

    assert result["relative_path"] == "work/new.txt"
    assert File.read!(Path.join([project["folder_path"], "work", "new.txt"])) == "hello old"

    assert {:error, failed} =
             execute(
               "write",
               %{"path" => "work/new.txt", "content" => "again"},
               context,
               active_tools: ["write"]
             )

    assert failed["error"]["code"] == "file_exists"

    sha = ProjectFile.sha256("hello old")

    assert {:ok, result} =
             execute(
               "edit",
               %{
                 "path" => "work/new.txt",
                 "old_text" => "old",
                 "new_text" => "new",
                 "expected_sha256" => sha
               },
               context,
               active_tools: ["edit"]
             )

    assert result["changed"] == true
    assert File.read!(Path.join([project["folder_path"], "work", "new.txt"])) == "hello new"

    File.write!(Path.join([project["folder_path"], "output", "file.txt"]), "x")

    assert {:error, failed} =
             execute(
               "edit",
               %{"path" => "output/file.txt", "old_text" => "x", "new_text" => "y"},
               context,
               active_tools: ["edit"]
             )

    assert failed["error"]["code"] == "path_denied"

    assert {:error, failed} =
             execute(
               "write",
               %{"path" => ".avcs/nope.txt", "content" => "x"},
               context,
               active_tools: ["write"]
             )

    assert failed["error"]["code"] == "path_denied"

    outside_dir = Path.join(System.tmp_dir!(), "avcs-tools-write-outside")
    File.rm_rf!(outside_dir)
    File.mkdir_p!(outside_dir)
    File.ln_s!(outside_dir, Path.join([project["folder_path"], "work", "linked-dir"]))

    assert {:error, failed} =
             execute(
               "write",
               %{"path" => "work/linked-dir/escape.txt", "content" => "x"},
               context,
               active_tools: ["write"]
             )

    assert failed["error"]["code"] == "symlink_denied"

    assert_tool_traced(project, context, "write")
    assert_tool_traced(project, context, "edit")
  end

  test "write registers output images as assets and board items", %{
    project: project,
    context: context
  } do
    assert {:ok, result} =
             execute(
               "write",
               %{
                 "path" => "output/write-image.png",
                 "content" => Base.encode64(test_png()),
                 "encoding" => "base64"
               },
               context,
               active_tools: ["write"]
             )

    assert result["asset"]["relative_path"] == "output/write-image.png"

    {:ok, assets} = Avcs.Assets.list_assets(project)
    assert [%{"relative_path" => "output/write-image.png", "source" => "generated"}] = assets

    {:ok, board_items} = Avcs.Board.list_items(project)
    assert [%{"asset_id" => asset_id}] = board_items
    assert asset_id == hd(assets)["id"]

    assert_tool_traced(project, context, "write")
  end

  test "image_gen validates OpenAI image option relationships before calling client", %{
    context: context
  } do
    context = Map.put(context, :image_model, "openai/gpt-image-2")

    assert {:error, failed} =
             execute(
               "image_gen",
               %{
                 "prompt" => "transparent logo",
                 "background" => "transparent",
                 "output_format" => "jpeg"
               },
               context
             )

    assert failed["error"]["code"] == "invalid_image_option"
    assert failed["error"]["message"] == "transparent background requires png or webp"

    assert {:error, failed} =
             execute(
               "image_gen",
               %{
                 "prompt" => "transparent logo",
                 "background" => "transparent",
                 "output_format" => "png"
               },
               context
             )

    assert failed["error"]["code"] == "unsupported_image_option"
    assert failed["error"]["message"] == "gpt-image-2 does not support transparent background"

    assert {:error, failed} =
             execute(
               "image_gen",
               %{
                 "prompt" => "compressed png",
                 "output_format" => "png",
                 "output_compression" => 80
               },
               context
             )

    assert failed["error"]["code"] == "invalid_image_option"
    assert failed["error"]["message"] == "output_compression requires jpeg or webp output_format"
  end

  test "image_gen drops APOD provider references for Vercel image-only models", %{
    context: context
  } do
    Application.put_env(:avcs, :avcs_agent_client, ImageGenCaptureClient)
    Application.put_env(:avcs, :image_gen_capture_pid, self())

    context =
      context
      |> Map.put(:image_model, "openai/gpt-image-2")
      |> Map.put(:base_url, "https://ai-gateway.vercel.sh/v1")
      |> Map.put(:data_provider_context, %{
        "result" => %{
          "asset_id" => "provider-asset",
          "media_type" => "image",
          "title" => "Fake APOD"
        }
      })

    assert {:ok, result} =
             execute(
               "image_gen",
               %{
                 "prompt" => "Create a poster from Fake APOD summary.",
                 "reference_asset_ids" => ["provider-asset"],
                 "size" => "1024x1024"
               },
               context
             )

    assert_receive {:image_gen_capture, "Create a poster from Fake APOD summary.", image_opts},
                   1_000

    assert Keyword.get(image_opts, :reference_images) == []
    assert result["reference_asset_ids"] == []
    assert result["reference_count"] == 0
  end

  test "image_gen rejects non-provider references for Vercel image-only models", %{
    context: context
  } do
    context =
      context
      |> Map.put(:image_model, "openai/gpt-image-2")
      |> Map.put(:base_url, "https://ai-gateway.vercel.sh/v1")

    assert {:error, failed} =
             execute(
               "image_gen",
               %{
                 "prompt" => "Use my reference",
                 "reference_asset_ids" => ["user-reference-asset"]
               },
               context
             )

    assert failed["error"]["code"] == "unsupported_reference_images"
    assert failed["error"]["message"] =~ "does not support reference images"
    assert failed["error"]["message"] =~ "openai/gpt-image-2"
  end

  test "bash only runs allowlisted provider descriptors and registers provider images", %{
    project: project,
    context: context
  } do
    script_path = fake_apod_script!(project)

    Application.put_env(:avcs, :data_provider_scripts, %{
      "avcs-data-prodiver-apod" => script_path
    })

    assert {:error, failed} =
             execute(
               "bash",
               %{"command" => "echo unsafe"},
               context
             )

    assert failed["error"]["code"] == "command_not_allowed"

    assert {:ok, result} =
             execute(
               "bash",
               %{
                 "command_kind" => "data_provider",
                 "provider" => "apod",
                 "args" => %{"date" => "2026-06-01"}
               },
               context
             )

    assert result["provider_status"] == "success"
    assert result["asset_id"]
    assert result["summary"]["title"] == "Fake APOD"
    assert String.starts_with?(result["relative_path"], "work/")

    {:ok, assets} = Avcs.Assets.list_assets(project)
    assert [%{"source" => "provider", "relative_path" => "work/" <> _rest}] = assets

    assert_tool_traced(project, context, "bash")

    {:ok, events} = Avcs.Trace.list_events(project, context.thread_id, turn_id: context.turn_id)

    assert Enum.any?(
             events,
             &(&1["event_name"] == "bash_command" and &1["status"] == "completed")
           )

    assert Enum.any?(events, fn event ->
             event["event_name"] == "preToolUse" and
               event["status"] == "completed" and
               get_in(event, ["payload", "tool_name"]) == "bash" and
               get_in(event, ["payload", "arguments", "args", "prefer_hd"]) == false
           end)
  end

  test "bash reports provider timeouts explicitly", %{
    project: project,
    context: context
  } do
    Application.put_env(:avcs, :data_provider_timeout_ms, 50)

    Application.put_env(:avcs, :data_provider_scripts, %{
      "avcs-data-prodiver-apod" => slow_apod_script!(project)
    })

    assert {:error, failed} =
             execute(
               "bash",
               %{
                 "command_kind" => "data_provider",
                 "provider" => "apod"
               },
               context
             )

    assert failed["error"]["code"] == "provider_timeout"
    assert failed["error"]["message"] == "Data provider timed out before returning JSON"

    {:ok, events} = Avcs.Trace.list_events(project, context.thread_id, turn_id: context.turn_id)

    assert Enum.any?(events, fn event ->
             event["event_name"] == "bash_command" and
               event["status"] == "failed" and
               get_in(event, ["payload", "timed_out"]) == true
           end)
  end

  defp execute(name, arguments, context, opts \\ []) do
    Avcs.Agent.Tools.Registry.execute(
      %{
        "id" => "tool-#{name}",
        "name" => name,
        "arguments" => Jason.encode!(arguments)
      },
      context,
      opts
    )
  end

  defp tool_event?(event, event_name, tool_name, status) do
    event["event_name"] == event_name and event["status"] == status and
      get_in(event, ["payload", "tool_name"]) == tool_name
  end

  defp assert_tool_traced(project, context, tool_name) do
    {:ok, events} = Avcs.Trace.list_events(project, context.thread_id, turn_id: context.turn_id)
    assert Enum.any?(events, &tool_event?(&1, "preToolUse", tool_name, "completed"))
    assert Enum.any?(events, &tool_event?(&1, "postToolUse", tool_name, "completed"))
  end

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
        "image_path": str(image_path.resolve())
      }
    }))
    """)

    script_path
  end

  defp slow_apod_script!(project) do
    script_path = Path.join(project["folder_path"], "work/slow_fetch_apod.py")

    File.write!(script_path, """
    import time

    time.sleep(1)
    """)

    script_path
  end

  defp test_png do
    Base.decode64!(
      "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII="
    )
  end
end
