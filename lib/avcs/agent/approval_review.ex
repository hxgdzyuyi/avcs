defmodule Avcs.Agent.ApprovalReview do
  @moduledoc false

  def started_item_attrs(thread_id, turn_id, params, raw) do
    item_attrs(thread_id, turn_id, params, raw, item_status(params), "started")
  end

  def completed_item_attrs(thread_id, turn_id, params, raw) do
    item_attrs(thread_id, turn_id, params, raw, item_status(params), "completed")
  end

  def response_payload(item, decision) do
    payload = item["payload"] || %{}

    Map.merge(payload, %{
      "user_decision" => decision,
      "responded_at" => Avcs.Time.now_iso()
    })
  end

  def event_from_item(item) do
    payload = item["payload"] || %{}
    payload["event"] || get_in(payload, ["raw", "params"])
  end

  def item_status(%{"review" => %{"status" => "inProgress"}}), do: "pending"
  def item_status(%{"review" => %{"status" => status}}) when is_binary(status), do: status
  def item_status(_params), do: "pending"

  def action_summary(%{"action" => action}), do: action_summary(action)

  def action_summary(%{"type" => "command"} = action) do
    action["command"] || "Command"
  end

  def action_summary(%{"type" => "execve"} = action) do
    [action["program"] | action["argv"] || []]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
    |> case do
      "" -> "Execute program"
      summary -> summary
    end
  end

  def action_summary(%{"type" => "applyPatch"} = action) do
    action
    |> Map.get("files", [])
    |> Enum.join(", ")
    |> case do
      "" -> "Apply patch"
      files -> "Apply patch: #{files}"
    end
  end

  def action_summary(%{"type" => "networkAccess"} = action) do
    [
      action["protocol"],
      action["target"] || action["host"],
      action["port"]
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
    |> case do
      "" -> "Network access"
      target -> "Network access: #{target}"
    end
  end

  def action_summary(%{"type" => "mcpToolCall"} = action) do
    [
      action["connectorName"],
      action["server"],
      action["toolTitle"] || action["toolName"]
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" / ")
    |> case do
      "" -> "MCP tool call"
      summary -> summary
    end
  end

  def action_summary(%{"type" => "requestPermissions"} = action) do
    action["reason"] || "Request permissions"
  end

  def action_summary(%{"type" => type}) when is_binary(type), do: type
  def action_summary(_action), do: "Approval request"

  defp item_attrs(thread_id, turn_id, params, raw, status, phase) do
    review_id = review_id(params)

    [
      turn_id: turn_id,
      thread_id: thread_id,
      remote_item_id: review_id,
      type: "approval_request",
      role: "system",
      content: action_summary(params),
      status: status,
      payload: %{
        review_id: review_id,
        target_item_id: target_item_id(params),
        action: params["action"],
        review: params["review"],
        event: params,
        raw: raw,
        phase: phase
      }
    ]
  end

  defp review_id(params) do
    params["reviewId"] || params["review_id"] || params["id"] ||
      "approval-#{:erlang.phash2(params)}"
  end

  defp target_item_id(params), do: params["targetItemId"] || params["target_item_id"]
end
