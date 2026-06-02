defmodule Avcs.Agent.CodexSchema do
  @moduledoc false

  require Logger

  @schema_files %{
    agent_message_delta_notification: "v2/AgentMessageDeltaNotification.json",
    error_notification: "v2/ErrorNotification.json",
    item_auto_approval_review_completed_notification:
      "v2/ItemGuardianApprovalReviewCompletedNotification.json",
    item_auto_approval_review_started_notification:
      "v2/ItemGuardianApprovalReviewStartedNotification.json",
    item_completed_notification: "v2/ItemCompletedNotification.json",
    item_started_notification: "v2/ItemStartedNotification.json",
    model_list_params: "v2/ModelListParams.json",
    model_list_response: "v2/ModelListResponse.json",
    thread_approve_guardian_denied_action_params:
      "v2/ThreadApproveGuardianDeniedActionParams.json",
    thread_approve_guardian_denied_action_response:
      "v2/ThreadApproveGuardianDeniedActionResponse.json",
    thread_name_updated_notification: "v2/ThreadNameUpdatedNotification.json",
    thread_read_params: "v2/ThreadReadParams.json",
    thread_read_response: "v2/ThreadReadResponse.json",
    thread_resume_params: "v2/ThreadResumeParams.json",
    thread_resume_response: "v2/ThreadResumeResponse.json",
    thread_start_params: "v2/ThreadStartParams.json",
    thread_start_response: "v2/ThreadStartResponse.json",
    turn_completed_notification: "v2/TurnCompletedNotification.json",
    turn_started_notification: "v2/TurnStartedNotification.json",
    turn_start_params: "v2/TurnStartParams.json",
    turn_start_response: "v2/TurnStartResponse.json"
  }

  def schema_names, do: @schema_files |> Map.keys() |> Enum.sort()

  def schema_path(schema_name) do
    with {:ok, file} <- Map.fetch(@schema_files, schema_name),
         {:ok, priv_dir} <- priv_dir() do
      {:ok, Path.join([priv_dir, "codex_app_server", "schemas", file])}
    else
      :error -> {:error, {:unknown_schema, schema_name}}
      error -> error
    end
  end

  def validate(schema_name, value) do
    with {:ok, schema} <- schema(schema_name),
         {:ok, json_value} <- normalize_json_value(value) do
      JsonXema.validate(schema, json_value)
    end
  end

  def validate_runtime(schema_name, value, context \\ nil) do
    if Application.get_env(:avcs, :codex_schema_validation, false) do
      case validate(schema_name, value) do
        :ok ->
          :ok

        {:error, reason} = error ->
          Logger.warning(fn ->
            "Codex app-server schema validation failed for #{schema_label(schema_name, context)}: #{inspect(reason)}"
          end)

          error
      end
    else
      :ok
    end
  end

  defp schema(schema_name) do
    cache_key = {__MODULE__, :schema, schema_name}

    case :persistent_term.get(cache_key, :missing) do
      :missing ->
        with {:ok, path} <- schema_path(schema_name),
             {:ok, raw_schema} <- File.read(path),
             {:ok, decoded_schema} <- Jason.decode(raw_schema) do
          schema = JsonXema.new(decoded_schema)
          :persistent_term.put(cache_key, schema)
          {:ok, schema}
        else
          {:error, reason} -> {:error, {:schema_load_failed, schema_name, reason}}
        end

      schema ->
        {:ok, schema}
    end
  rescue
    exception ->
      {:error, {:schema_compile_failed, schema_name, Exception.message(exception)}}
  end

  defp normalize_json_value(value) do
    with {:ok, encoded} <- Jason.encode(value),
         {:ok, decoded} <- Jason.decode(encoded) do
      {:ok, decoded}
    else
      {:error, reason} -> {:error, {:json_normalize_failed, reason}}
    end
  end

  defp priv_dir do
    case :code.priv_dir(:avcs) do
      {:error, reason} -> {:error, {:priv_dir_unavailable, reason}}
      path -> {:ok, to_string(path)}
    end
  end

  defp schema_label(schema_name, nil), do: to_string(schema_name)
  defp schema_label(schema_name, context), do: "#{schema_name} #{context}"
end
