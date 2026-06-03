defmodule Avcs.Agent.CodexClientTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog

  setup do
    previous_executable = fetch_env(:codex_executable)
    previous_search_paths = fetch_env(:codex_search_paths)
    previous_server = fetch_env(:codex_client_server)
    previous_validation = fetch_env(:codex_schema_validation)
    previous_request_timeout = fetch_env(:codex_request_timeout_ms)
    previous_idle_timeout = fetch_env(:codex_idle_timeout_ms)
    previous_path = System.get_env("PATH")
    previous_home = System.get_env("HOME")
    previous_codex_executable_env = System.get_env("AVCS_CODEX_EXECUTABLE")
    previous_log = System.get_env("AVCS_FAKE_CODEX_LOG")
    previous_events = System.get_env("AVCS_FAKE_CODEX_EVENTS")
    previous_requests = System.get_env("AVCS_FAKE_CODEX_REQUESTS")
    previous_mode = System.get_env("AVCS_FAKE_CODEX_MODE")
    previous_child_path_log = System.get_env("AVCS_FAKE_CODEX_CHILD_PATH_LOG")

    tmp_dir =
      Path.join(System.tmp_dir!(), "avcs-codex-client-#{System.unique_integer([:positive])}")

    File.rm_rf!(tmp_dir)
    File.mkdir_p!(tmp_dir)

    log_path = Path.join(tmp_dir, "pids.log")
    events_path = Path.join(tmp_dir, "events.log")
    requests_path = Path.join(tmp_dir, "requests.log")
    script_path = Path.join(tmp_dir, "fake-codex")
    File.write!(script_path, fake_codex_script())
    File.chmod!(script_path, 0o755)

    worker = start_supervised!({Avcs.Agent.CodexClient, name: nil})

    Application.put_env(:avcs, :codex_client_server, worker)
    Application.put_env(:avcs, :codex_executable, script_path)
    Application.put_env(:avcs, :codex_schema_validation, false)
    System.put_env("AVCS_FAKE_CODEX_LOG", log_path)
    System.put_env("AVCS_FAKE_CODEX_EVENTS", events_path)
    System.put_env("AVCS_FAKE_CODEX_REQUESTS", requests_path)
    System.put_env("AVCS_FAKE_CODEX_MODE", "normal")

    on_exit(fn ->
      restore_env(:codex_executable, previous_executable)
      restore_env(:codex_search_paths, previous_search_paths)
      restore_env(:codex_client_server, previous_server)
      restore_env(:codex_schema_validation, previous_validation)
      restore_env(:codex_request_timeout_ms, previous_request_timeout)
      restore_env(:codex_idle_timeout_ms, previous_idle_timeout)
      restore_system_env("PATH", previous_path)
      restore_system_env("HOME", previous_home)
      restore_system_env("AVCS_CODEX_EXECUTABLE", previous_codex_executable_env)
      restore_system_env("AVCS_FAKE_CODEX_LOG", previous_log)
      restore_system_env("AVCS_FAKE_CODEX_EVENTS", previous_events)
      restore_system_env("AVCS_FAKE_CODEX_REQUESTS", previous_requests)
      restore_system_env("AVCS_FAKE_CODEX_MODE", previous_mode)
      restore_system_env("AVCS_FAKE_CODEX_CHILD_PATH_LOG", previous_child_path_log)
      File.rm_rf!(tmp_dir)
    end)

    %{
      events_path: events_path,
      log_path: log_path,
      requests_path: requests_path,
      script_path: script_path,
      tmp_dir: tmp_dir,
      worker: worker
    }
  end

  test "list_models reuses the same app-server port process", %{log_path: log_path} do
    assert {:ok, [%{"id" => "fake-model"}]} = Avcs.Agent.CodexClient.list_models()
    assert {:ok, [%{"id" => "fake-model"}]} = Avcs.Agent.CodexClient.list_models()

    assert [pid] =
             log_path
             |> File.read!()
             |> String.split("\n", trim: true)
             |> Enum.uniq()

    assert pid != ""
  end

  test "list_models discovers codex from an nvm install outside the app PATH", %{
    script_path: script_path,
    tmp_dir: tmp_dir
  } do
    home = Path.join(tmp_dir, "home")
    nvm_bin = Path.join([home, ".nvm", "versions", "node", "v22.18.0", "bin"])
    discovered_codex = Path.join(nvm_bin, "codex")
    child_path_log = Path.join(tmp_dir, "child-path.log")

    File.mkdir_p!(nvm_bin)
    File.cp!(script_path, discovered_codex)
    File.chmod!(discovered_codex, 0o755)

    Application.delete_env(:avcs, :codex_executable)
    Application.delete_env(:avcs, :codex_search_paths)
    System.delete_env("AVCS_CODEX_EXECUTABLE")
    System.put_env("HOME", home)
    System.put_env("PATH", "/usr/bin:/bin:/usr/sbin:/sbin")
    System.put_env("AVCS_FAKE_CODEX_CHILD_PATH_LOG", child_path_log)

    assert {:ok, [%{"id" => "fake-model"}]} = Avcs.Agent.CodexClient.list_models()

    assert child_path_log
           |> File.read!()
           |> String.split(":", trim: true)
           |> List.first() == nvm_bin
  end

  test "run_turn is driven by app-server messages without restarting the port", %{
    log_path: log_path
  } do
    project = open_test_project()

    assert {:ok, result} =
             Avcs.Agent.CodexClient.run_turn(
               project,
               nil,
               "Say hi",
               [],
               fn _event -> :ok end,
               %{}
             )

    assert result.codex_thread_id == "thread-1"
    assert result.codex_turn_id == "turn-1"
    assert result.assistant_text == "Hello from fake Codex"
    assert result.thread_name == "Fake Thread Updated"

    assert [_pid] =
             log_path
             |> File.read!()
             |> String.split("\n", trim: true)
             |> Enum.uniq()
  end

  test "run_turn parses image generation notifications split by the port line limit" do
    System.put_env("AVCS_FAKE_CODEX_MODE", "large_image_generation")
    project = open_test_project()

    assert {:ok, result} =
             Avcs.Agent.CodexClient.run_turn(
               project,
               nil,
               "Create a large image",
               [],
               fn _event -> :ok end,
               %{}
             )

    assert result.codex_thread_id == "thread-1"
    assert result.codex_turn_id == "turn-1"

    assert image_item =
             Enum.find(result.items, &(&1["id"] == "image-1" and &1["type"] == "imageGeneration"))

    assert image_item["status"] == "completed"
    assert image_item["savedPath"] == "/tmp/fake-image.png"
    refute Map.has_key?(image_item, "result")
    assert image_item["result_omitted"] == true
    assert image_item["result_size_bytes"] == 150_000
  end

  test "read_thread requests full turns and compacts large image results", %{
    requests_path: requests_path
  } do
    System.put_env("AVCS_FAKE_CODEX_MODE", "thread_read_turns")

    assert {:ok, thread} = Avcs.Agent.CodexClient.read_thread("thread-1", include_turns: true)
    assert thread["id"] == "thread-1"

    assert [turn] = thread["turns"]
    assert turn["id"] == "turn-1"

    assert image_item =
             Enum.find(
               turn["items"],
               &(&1["id"] == "image-1" and &1["type"] == "imageGeneration")
             )

    refute Map.has_key?(image_item, "result")
    assert image_item["result_omitted"] == true
    assert image_item["result_size_bytes"] == 150_000

    assert File.read!(requests_path) =~ ~s("includeTurns":true)
  end

  test "run_turn sends rendered Avcs imagegen runtime instructions", %{
    requests_path: requests_path
  } do
    project = open_test_project()

    assert {:ok, _result} =
             Avcs.Agent.CodexClient.run_turn(
               project,
               nil,
               "Create an image",
               [],
               fn _event -> :ok end,
               %{}
             )

    thread_start =
      requests_path
      |> read_requests!()
      |> Enum.find(&(&1["method"] == "thread/start"))

    instructions = get_in(thread_start, ["params", "developerInstructions"])

    assert instructions =~ "当前项目路径：#{Path.expand(Avcs.Projects.folder_path(project))}"
    assert instructions =~ "当前项目输出目录：#{Path.expand(Avcs.Projects.output_dir(project))}"
    assert instructions =~ "当前 thread 中必须禁用系统 `imagegen` skill"
    assert instructions =~ "系统 `imagegen` skill 的触发条件是"
    assert instructions =~ "不要将图片任务改写成 HTML/CSS/DOM/SVG/Canvas/WebGL 页面"
    assert instructions =~ "不要通过 Chrome、Chromium、Playwright、Puppeteer"
    assert instructions =~ "不要改用 HTML 排版或浏览器截图"
    assert instructions =~ "/skills/avcs-imagegen/SKILL.md"
    refute instructions =~ "{{project_path}}"
    refute instructions =~ "{{project_output_dir}}"
    refute instructions =~ "{{avcs_imagegen_skill_path}}"
  end

  test "run_turn reuses an already loaded thread without resuming it", %{
    events_path: events_path,
    log_path: log_path
  } do
    project = open_test_project()

    assert {:ok, first_result} =
             Avcs.Agent.CodexClient.run_turn(
               project,
               nil,
               "First turn",
               [],
               fn _event -> :ok end,
               %{}
             )

    assert {:ok, second_result} =
             Avcs.Agent.CodexClient.run_turn(
               project,
               first_result.codex_thread_id,
               "Second turn",
               [],
               fn _event -> :ok end,
               %{}
             )

    assert second_result.codex_thread_id == first_result.codex_thread_id

    events =
      events_path
      |> File.read!()
      |> String.split("\n", trim: true)

    assert Enum.count(events, &(&1 == "thread-start")) == 1
    refute Enum.member?(events, "thread-resume")
    assert Enum.count(events, &(&1 == "turn-start")) == 2

    assert [_pid] =
             log_path
             |> File.read!()
             |> String.split("\n", trim: true)
             |> Enum.uniq()
  end

  test "run_turn falls back to thread preview when app-server thread name is missing" do
    System.put_env("AVCS_FAKE_CODEX_MODE", "preview_title")
    project = open_test_project()

    assert {:ok, result} =
             Avcs.Agent.CodexClient.run_turn(
               project,
               nil,
               "Make three logo concepts",
               [],
               fn _event -> :ok end,
               %{}
             )

    assert result.thread_name == "Make three logo concepts"
  end

  test "run_turn keeps running while app-server turn events continue arriving" do
    System.put_env("AVCS_FAKE_CODEX_MODE", "active_pulses")
    Application.put_env(:avcs, :codex_request_timeout_ms, 1_000)
    Application.put_env(:avcs, :codex_idle_timeout_ms, 500)
    project = open_test_project()

    assert {:ok, result} =
             Avcs.Agent.CodexClient.run_turn(
               project,
               nil,
               "Keep going",
               [],
               fn _event -> :ok end,
               %{}
             )

    assert result.codex_thread_id == "thread-1"
    assert result.codex_turn_id == "turn-1"
    assert result.assistant_text == "pulse-1 pulse-2 pulse-3"
  end

  test "run_turn keeps running when turn notifications arrive before turn/start response" do
    System.put_env("AVCS_FAKE_CODEX_MODE", "delayed_turn_start_response")
    Application.put_env(:avcs, :codex_request_timeout_ms, 1_000)
    Application.put_env(:avcs, :codex_idle_timeout_ms, 500)
    project = open_test_project()

    assert {:ok, result} =
             Avcs.Agent.CodexClient.run_turn(
               project,
               nil,
               "Keep going before response",
               [],
               fn _event -> :ok end,
               %{}
             )

    assert result.codex_thread_id == "thread-1"
    assert result.codex_turn_id == "turn-1"
    assert result.assistant_text == "early-1 early-2"
  end

  test "run_turn waits past request timeout after turn/start has been sent" do
    System.put_env("AVCS_FAKE_CODEX_MODE", "slow_turn_start_response")
    Application.put_env(:avcs, :codex_request_timeout_ms, 500)
    Application.put_env(:avcs, :codex_idle_timeout_ms, 2_000)
    project = open_test_project()

    assert {:ok, result} =
             Avcs.Agent.CodexClient.run_turn(
               project,
               nil,
               "Slow start",
               [],
               fn _event -> :ok end,
               %{}
             )

    assert result.codex_thread_id == "thread-1"
    assert result.codex_turn_id == "turn-1"
    assert result.assistant_text == "slow-start-ok"
  end

  test "run_turn fails idle turns and cleans up the app-server", %{
    events_path: events_path,
    log_path: log_path
  } do
    System.put_env("AVCS_FAKE_CODEX_MODE", "hanging_turn")
    Application.put_env(:avcs, :codex_request_timeout_ms, 1_000)
    Application.put_env(:avcs, :codex_idle_timeout_ms, 150)
    project = open_test_project()

    task =
      Task.async(fn ->
        Avcs.Agent.CodexClient.run_turn(project, nil, "Hang", [], fn _event -> :ok end, %{})
      end)

    wait_for_event(events_path, "hanging-turn")
    pid = read_logged_pid!(log_path)

    assert {:error, "Codex app-server idle timed out"} = Task.await(task, 2_000)
    assert_pid_dead(pid)
  end

  test "steer_turn sends expected active turn params", %{
    events_path: events_path,
    requests_path: requests_path,
    worker: worker
  } do
    System.put_env("AVCS_FAKE_CODEX_MODE", "hanging_turn")
    project = open_test_project()
    image_path = Path.join(Avcs.Projects.work_dir(project), "reference.png")
    File.write!(image_path, "fake")

    task =
      Task.async(fn ->
        Avcs.Agent.CodexClient.run_turn(project, nil, "Hang", [], fn _event -> :ok end, %{})
      end)

    wait_for_event(events_path, "hanging-turn")

    assert {:ok, %{"turnId" => "turn-1"}} =
             Avcs.Agent.CodexClient.steer_turn_on(worker, "Use this", [image_path])

    wait_for_event(events_path, "turn-steer")

    steer_request =
      requests_path
      |> read_requests!()
      |> Enum.find(&(&1["method"] == "turn/steer"))

    assert get_in(steer_request, ["params", "threadId"]) == "thread-1"
    assert get_in(steer_request, ["params", "expectedTurnId"]) == "turn-1"
    assert %{"type" => "text", "text" => text} = hd(get_in(steer_request, ["params", "input"]))
    assert text =~ "Use this"
    assert Enum.any?(get_in(steer_request, ["params", "input"]), &(&1["path"] == image_path))

    assert :ok = stop_supervised(Avcs.Agent.CodexClient)
    assert {:error, "Codex app-server stopped"} = Task.await(task, 1_000)
  end

  test "steer_turn rejection does not stop the active turn", %{
    events_path: events_path,
    worker: worker
  } do
    System.put_env("AVCS_FAKE_CODEX_MODE", "steer_reject")
    project = open_test_project()

    task =
      Task.async(fn ->
        Avcs.Agent.CodexClient.run_turn(project, nil, "Hang", [], fn _event -> :ok end, %{})
      end)

    wait_for_event(events_path, "hanging-turn")

    assert {:error, "steer rejected"} =
             Avcs.Agent.CodexClient.steer_turn_on(worker, "Rejected steer", [])

    wait_for_event(events_path, "turn-steer")

    assert :ok = stop_supervised(Avcs.Agent.CodexClient)
    assert {:error, "Codex app-server stopped"} = Task.await(task, 1_000)
  end

  test "interrupt_turn sends active thread and turn ids", %{
    events_path: events_path,
    requests_path: requests_path,
    worker: worker
  } do
    System.put_env("AVCS_FAKE_CODEX_MODE", "hanging_turn")
    project = open_test_project()

    task =
      Task.async(fn ->
        Avcs.Agent.CodexClient.run_turn(project, nil, "Hang", [], fn _event -> :ok end, %{})
      end)

    wait_for_event(events_path, "hanging-turn")

    assert {:ok, %{}} = Avcs.Agent.CodexClient.interrupt_turn_on(worker, nil, nil)

    wait_for_event(events_path, "turn-interrupt")

    interrupt_request =
      requests_path
      |> read_requests!()
      |> Enum.find(&(&1["method"] == "turn/interrupt"))

    assert get_in(interrupt_request, ["params", "threadId"]) == "thread-1"
    assert get_in(interrupt_request, ["params", "turnId"]) == "turn-1"
    assert {:error, :interrupted} = Task.await(task, 1_000)
  end

  test "stopping an idle client stops its app-server process", %{log_path: log_path} do
    assert {:ok, [%{"id" => "fake-model"}]} = Avcs.Agent.CodexClient.list_models()
    pid = read_logged_pid!(log_path)

    assert :ok = stop_supervised(Avcs.Agent.CodexClient)
    assert_pid_dead(pid)
  end

  test "stopping an active turn replies with a stopped error and cleans up the app-server", %{
    events_path: events_path,
    log_path: log_path
  } do
    System.put_env("AVCS_FAKE_CODEX_MODE", "hanging_turn")
    project = open_test_project()

    task =
      Task.async(fn ->
        Avcs.Agent.CodexClient.run_turn(project, nil, "Hang", [], fn _event -> :ok end, %{})
      end)

    wait_for_event(events_path, "hanging-turn")
    pid = read_logged_pid!(log_path)

    assert :ok = stop_supervised(Avcs.Agent.CodexClient)
    assert {:error, "Codex app-server stopped"} = Task.await(task, 1_000)
    assert_pid_dead(pid)
  end

  test "stopping a client kills an app-server that ignores SIGTERM", %{log_path: log_path} do
    System.put_env("AVCS_FAKE_CODEX_MODE", "ignore_term")

    assert {:ok, [%{"id" => "fake-model"}]} = Avcs.Agent.CodexClient.list_models()
    pid = read_logged_pid!(log_path)

    log =
      capture_log(fn ->
        assert :ok = stop_supervised(Avcs.Agent.CodexClient)
      end)

    assert log =~ "did not terminate gracefully, using SIGKILL"
    assert_pid_dead(pid)
  end

  defp fake_codex_script do
    """
    #!/bin/sh
    mode="${AVCS_FAKE_CODEX_MODE:-normal}"

    event_log() {
      if [ -n "$AVCS_FAKE_CODEX_EVENTS" ]; then
        printf '%s\\n' "$1" >> "$AVCS_FAKE_CODEX_EVENTS"
      fi
    }

    request_log() {
      if [ -n "$AVCS_FAKE_CODEX_REQUESTS" ]; then
        printf '%s\\n' "$1" >> "$AVCS_FAKE_CODEX_REQUESTS"
      fi
    }

    if [ "$mode" = "ignore_term" ]; then
      trap '' TERM HUP INT
    fi

    if [ -n "$AVCS_FAKE_CODEX_CHILD_PATH_LOG" ]; then
      printf '%s\\n' "$PATH" > "$AVCS_FAKE_CODEX_CHILD_PATH_LOG"
    fi

    printf '%s\\n' "$$" >> "$AVCS_FAKE_CODEX_LOG"
    event_log started

    while IFS= read -r line
    do
      request_log "$line"
      id=$(printf '%s' "$line" | sed -n 's/.*"id":\\([0-9][0-9]*\\).*/\\1/p')
      if [ -z "$id" ]; then id=0; fi

      case "$line" in
        *\\"method\\":\\"initialize\\"*)
          event_log initialize
          printf '%s\\n' "{\\"id\\":$id,\\"result\\":{}}"
          ;;
        *\\"method\\":\\"model/list\\"*)
          event_log model-list
          printf '%s\\n' "{\\"id\\":$id,\\"result\\":{\\"data\\":[{\\"id\\":\\"fake-model\\"}]}}"
          ;;
        *\\"method\\":\\"thread/start\\"*)
          event_log thread-start
          printf '%s\\n' "{\\"id\\":$id,\\"result\\":{\\"thread\\":{\\"id\\":\\"thread-1\\",\\"name\\":\\"Fake Thread\\"}}}"
          ;;
        *\\"method\\":\\"thread/resume\\"*)
          event_log thread-resume
          printf '%s\\n' "{\\"id\\":$id,\\"result\\":{\\"thread\\":{\\"id\\":\\"thread-1\\",\\"name\\":\\"Fake Thread\\"}}}"
          ;;
        *\\"method\\":\\"turn/start\\"*)
          event_log turn-start
          if [ "$mode" = "slow_turn_start_response" ]; then
            event_log slow-turn-start-response
            sleep 0.75
            printf '%s\\n' "{\\"id\\":$id,\\"result\\":{\\"turn\\":{\\"id\\":\\"turn-1\\"}}}"
            printf '%s\\n' "{\\"method\\":\\"item/agentMessage/delta\\",\\"params\\":{\\"delta\\":\\"slow-start-ok\\"}}"
            printf '%s\\n' "{\\"method\\":\\"turn/completed\\",\\"params\\":{\\"turn\\":{\\"id\\":\\"turn-1\\",\\"status\\":\\"completed\\"}}}"
            continue
          fi
          if [ "$mode" = "delayed_turn_start_response" ]; then
            event_log delayed-turn-start-response
            printf '%s\\n' "{\\"method\\":\\"turn/started\\",\\"params\\":{\\"threadId\\":\\"thread-1\\",\\"turn\\":{\\"id\\":\\"turn-1\\"}}}"
            sleep 0.08
            printf '%s\\n' "{\\"method\\":\\"item/agentMessage/delta\\",\\"params\\":{\\"delta\\":\\"early-1 \\"}}"
            sleep 0.08
            printf '%s\\n' "{\\"method\\":\\"item/agentMessage/delta\\",\\"params\\":{\\"delta\\":\\"early-2\\"}}"
            sleep 0.08
            printf '%s\\n' "{\\"method\\":\\"turn/completed\\",\\"params\\":{\\"turn\\":{\\"id\\":\\"turn-1\\",\\"status\\":\\"completed\\"}}}"
            sleep 0.05
            printf '%s\\n' "{\\"id\\":$id,\\"result\\":{\\"turn\\":{\\"id\\":\\"turn-1\\"}}}"
            continue
          fi
          printf '%s\\n' "{\\"id\\":$id,\\"result\\":{\\"turn\\":{\\"id\\":\\"turn-1\\"}}}"
          if [ "$mode" = "hanging_turn" ] || [ "$mode" = "steer_reject" ]; then
            event_log hanging-turn
            continue
          fi
          if [ "$mode" = "active_pulses" ]; then
            sleep 0.25
            event_log active-pulse-1
            printf '%s\\n' "{\\"method\\":\\"item/agentMessage/delta\\",\\"params\\":{\\"delta\\":\\"pulse-1 \\"}}"
            sleep 0.25
            event_log active-pulse-2
            printf '%s\\n' "{\\"method\\":\\"item/agentMessage/delta\\",\\"params\\":{\\"delta\\":\\"pulse-2 \\"}}"
            sleep 0.25
            event_log active-pulse-3
            printf '%s\\n' "{\\"method\\":\\"item/agentMessage/delta\\",\\"params\\":{\\"delta\\":\\"pulse-3\\"}}"
            printf '%s\\n' "{\\"method\\":\\"turn/completed\\",\\"params\\":{\\"turn\\":{\\"id\\":\\"turn-1\\",\\"status\\":\\"completed\\"}}}"
            continue
          fi
          if [ "$mode" = "large_image_generation" ]; then
            payload=$(awk 'BEGIN { for (i = 0; i < 150000; i++) printf "A" }')
            printf '%s\\n' "{\\"method\\":\\"item/started\\",\\"params\\":{\\"item\\":{\\"id\\":\\"image-1\\",\\"type\\":\\"imageGeneration\\",\\"status\\":\\"in_progress\\"}}}"
            printf '%s%s%s\\n' '{"method":"item/completed","params":{"item":{"id":"image-1","type":"imageGeneration","status":"completed","savedPath":"/tmp/fake-image.png","result":"' "$payload" '"}}}'
            printf '%s\\n' "{\\"method\\":\\"turn/completed\\",\\"params\\":{\\"turn\\":{\\"id\\":\\"turn-1\\",\\"status\\":\\"completed\\"}}}"
            continue
          fi
          printf '%s\\n' "{\\"method\\":\\"item/agentMessage/delta\\",\\"params\\":{\\"delta\\":\\"Hello from fake Codex\\"}}"
          printf '%s\\n' "{\\"method\\":\\"turn/completed\\",\\"params\\":{\\"turn\\":{\\"id\\":\\"turn-1\\",\\"status\\":\\"completed\\"}}}"
          ;;
        *\\"method\\":\\"turn/steer\\"*)
          event_log turn-steer
          if [ "$mode" = "steer_reject" ]; then
            printf '%s\\n' "{\\"id\\":$id,\\"error\\":{\\"code\\":-32000,\\"message\\":\\"steer rejected\\"}}"
          else
            printf '%s\\n' "{\\"id\\":$id,\\"result\\":{\\"turnId\\":\\"turn-1\\"}}"
          fi
          ;;
        *\\"method\\":\\"turn/interrupt\\"*)
          event_log turn-interrupt
          printf '%s\\n' "{\\"id\\":$id,\\"result\\":{}}"
          printf '%s\\n' "{\\"method\\":\\"turn/completed\\",\\"params\\":{\\"turn\\":{\\"id\\":\\"turn-1\\",\\"status\\":\\"interrupted\\"}}}"
          ;;
        *\\"method\\":\\"thread/read\\"*)
          event_log thread-read
          if [ "$mode" = "thread_read_turns" ]; then
            payload=$(awk 'BEGIN { for (i = 0; i < 150000; i++) printf "A" }')
            printf '%s%s%s\\n' '{"id":'"$id"',"result":{"thread":{"id":"thread-1","name":"Recovered Thread","turns":[{"id":"turn-1","status":"completed","items":[{"id":"user-1","type":"userMessage","content":[{"type":"text","text":"Make an image"}]},{"id":"image-1","type":"imageGeneration","status":"completed","savedPath":"/tmp/fake-image.png","result":"' "$payload" '"}]}]}}}'
          elif [ "$mode" = "preview_title" ]; then
            printf '%s\\n' "{\\"id\\":$id,\\"result\\":{\\"thread\\":{\\"id\\":\\"thread-1\\",\\"name\\":null,\\"preview\\":\\"User request:\\nMake three logo concepts\\"}}}"
          else
            printf '%s\\n' "{\\"id\\":$id,\\"result\\":{\\"thread\\":{\\"id\\":\\"thread-1\\",\\"name\\":\\"Fake Thread Updated\\"}}}"
          fi
          ;;
      esac
    done

    if [ "$mode" = "ignore_term" ]; then
      event_log ignore-term-sleep
      while :
      do
        sleep 1
      done
    fi
    """
  end

  defp read_requests!(requests_path) do
    requests_path
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
  end

  defp open_test_project do
    project_dir =
      Path.join(
        System.tmp_dir!(),
        "avcs-codex-client-project-#{System.unique_integer([:positive])}"
      )

    File.rm_rf!(project_dir)
    {:ok, project} = Avcs.Projects.open_project(project_dir)

    on_exit(fn -> File.rm_rf!(project_dir) end)
    project
  end

  defp read_logged_pid!(log_path) do
    eventually(
      fn ->
        case logged_pids(log_path) do
          [pid | _rest] -> pid
          [] -> nil
        end
      end,
      "fake Codex pid was not logged"
    )
  end

  defp logged_pids(log_path) do
    if File.exists?(log_path) do
      log_path
      |> File.read!()
      |> String.split("\n", trim: true)
    else
      []
    end
  end

  defp wait_for_event(events_path, event) do
    eventually(
      fn -> event_logged?(events_path, event) end,
      "fake Codex event #{inspect(event)} was not logged"
    )
  end

  defp event_logged?(events_path, event) do
    File.exists?(events_path) and
      events_path
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.member?(event)
  end

  defp assert_pid_dead(pid) do
    eventually(fn -> not os_pid_alive?(pid) end, "OS process #{pid} was still alive")
  end

  defp eventually(fun, failure_message, timeout_ms \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_eventually(fun, deadline, failure_message)
  end

  defp do_eventually(fun, deadline, failure_message) do
    case fun.() do
      nil ->
        retry_eventually(fun, deadline, failure_message)

      false ->
        retry_eventually(fun, deadline, failure_message)

      value ->
        value
    end
  end

  defp retry_eventually(fun, deadline, failure_message) do
    if System.monotonic_time(:millisecond) >= deadline do
      flunk(failure_message)
    else
      Process.sleep(25)
      do_eventually(fun, deadline, failure_message)
    end
  end

  defp os_pid_alive?(pid) do
    case System.cmd("kill", ["-0", to_string(pid)], stderr_to_stdout: true) do
      {_output, 0} -> true
      {_output, _status} -> false
    end
  end

  defp fetch_env(key) do
    case Application.fetch_env(:avcs, key) do
      {:ok, value} -> {:set, value}
      :error -> :unset
    end
  end

  defp restore_env(key, {:set, value}), do: Application.put_env(:avcs, key, value)
  defp restore_env(key, :unset), do: Application.delete_env(:avcs, key)

  defp restore_system_env(key, nil), do: System.delete_env(key)
  defp restore_system_env(key, value), do: System.put_env(key, value)
end
