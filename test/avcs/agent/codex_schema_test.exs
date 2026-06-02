defmodule Avcs.Agent.CodexSchemaTest do
  use ExUnit.Case, async: true

  test "mapped schema files exist and compile" do
    for schema_name <- Avcs.Agent.CodexSchema.schema_names() do
      assert {:ok, path} = Avcs.Agent.CodexSchema.schema_path(schema_name)
      assert File.exists?(path)

      assert path
             |> File.read!()
             |> Jason.decode!()
             |> JsonXema.new()
    end
  end

  test "current request params validate against Codex app-server schemas" do
    cwd = File.cwd!()

    assert :ok =
             Avcs.Agent.CodexSchema.validate(:thread_start_params, %{
               cwd: cwd,
               approvalPolicy: "on-request",
               approvalsReviewer: "user",
               sandbox: "workspace-write",
               developerInstructions: "Use Avcs project defaults."
             })

    assert :ok =
             Avcs.Agent.CodexSchema.validate(:thread_resume_params, %{
               threadId: "thread-1"
             })

    assert :ok =
             Avcs.Agent.CodexSchema.validate(:turn_start_params, %{
               threadId: "thread-1",
               input: [
                 %{type: "text", text: "User request:\nMake logo options"},
                 %{type: "localImage", path: Path.join(cwd, "work/reference.png")}
               ],
               cwd: cwd,
               approvalPolicy: "on-request",
               approvalsReviewer: "user",
               sandboxPolicy: %{
                 type: "workspaceWrite",
                 writableRoots: [cwd],
                 networkAccess: true
               }
             })

    assert :ok =
             Avcs.Agent.CodexSchema.validate(:thread_read_params, %{
               threadId: "thread-1",
               includeTurns: false
             })
  end

  test "key responses and notifications validate against Codex app-server schemas" do
    assert :ok =
             Avcs.Agent.CodexSchema.validate(:turn_start_response, %{
               "turn" => %{"id" => "turn-1", "items" => [], "status" => "inProgress"}
             })

    assert :ok =
             Avcs.Agent.CodexSchema.validate(:thread_read_response, %{
               "thread" => thread_fixture()
             })

    assert :ok =
             Avcs.Agent.CodexSchema.validate(:agent_message_delta_notification, %{
               "threadId" => "thread-1",
               "turnId" => "turn-1",
               "itemId" => "item-1",
               "delta" => "Done"
             })

    assert :ok =
             Avcs.Agent.CodexSchema.validate(:thread_name_updated_notification, %{
               "threadId" => "thread-1",
               "threadName" => "Generated logo concepts"
             })

    assert :ok =
             Avcs.Agent.CodexSchema.validate(:item_started_notification, %{
               "threadId" => "thread-1",
               "turnId" => "turn-1",
               "startedAtMs" => 1_700_000_000_000,
               "item" => agent_message_item()
             })

    assert :ok =
             Avcs.Agent.CodexSchema.validate(:item_completed_notification, %{
               "threadId" => "thread-1",
               "turnId" => "turn-1",
               "completedAtMs" => 1_700_000_000_100,
               "item" => agent_message_item()
             })

    assert :ok =
             Avcs.Agent.CodexSchema.validate(:turn_completed_notification, %{
               "threadId" => "thread-1",
               "turn" => %{"id" => "turn-1", "items" => [], "status" => "completed"}
             })

    assert :ok =
             Avcs.Agent.CodexSchema.validate(:error_notification, %{
               "threadId" => "thread-1",
               "turnId" => "turn-1",
               "willRetry" => false,
               "error" => %{"message" => "Codex turn failed"}
             })

    approval_started = approval_review_fixture()

    assert :ok =
             Avcs.Agent.CodexSchema.validate(
               :item_auto_approval_review_started_notification,
               approval_started
             )

    assert :ok =
             Avcs.Agent.CodexSchema.validate(
               :item_auto_approval_review_completed_notification,
               Map.merge(approval_started, %{
                 "completedAtMs" => 1_700_000_000_200,
                 "decisionSource" => "agent",
                 "review" => %{"status" => "denied", "riskLevel" => "high"}
               })
             )

    assert :ok =
             Avcs.Agent.CodexSchema.validate(
               :thread_approve_guardian_denied_action_params,
               %{"threadId" => "thread-1", "event" => approval_started}
             )
  end

  test "invalid payloads fail schema validation" do
    assert {:error, %JsonXema.ValidationError{}} =
             Avcs.Agent.CodexSchema.validate(:thread_read_params, %{
               includeTurns: false
             })
  end

  defp agent_message_item do
    %{"id" => "item-1", "type" => "agentMessage", "text" => "Done"}
  end

  defp thread_fixture do
    %{
      "id" => "thread-1",
      "sessionId" => "session-1",
      "preview" => "Make logo options",
      "ephemeral" => false,
      "modelProvider" => "openai",
      "createdAt" => 1_700_000_000,
      "updatedAt" => 1_700_000_100,
      "status" => %{"type" => "idle"},
      "cwd" => File.cwd!(),
      "cliVersion" => "codex-cli 0.130.0",
      "source" => "appServer",
      "turns" => []
    }
  end

  defp approval_review_fixture do
    %{
      "threadId" => "thread-1",
      "turnId" => "turn-1",
      "reviewId" => "review-1",
      "targetItemId" => "item-1",
      "startedAtMs" => 1_700_000_000_100,
      "action" => %{
        "type" => "command",
        "command" => "echo render",
        "cwd" => File.cwd!(),
        "source" => "shell"
      },
      "review" => %{"status" => "inProgress", "riskLevel" => "high"}
    }
  end
end
