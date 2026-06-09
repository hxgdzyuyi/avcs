defmodule Avcs.Agent.Tools.Registry do
  @moduledoc false

  require Logger

  @tools [
    Avcs.Agent.Tools.ImageGen,
    Avcs.Agent.Tools.Read,
    Avcs.Agent.Tools.Ls,
    Avcs.Agent.Tools.Find,
    Avcs.Agent.Tools.Grep,
    Avcs.Agent.Tools.Bash,
    Avcs.Agent.Tools.Write,
    Avcs.Agent.Tools.Edit
  ]

  @default_active_tools ~w(image_gen read ls find grep bash)

  def schemas(opts \\ []) do
    opts
    |> active_tool_modules()
    |> Enum.map(&Avcs.Agent.Tool.schema/1)
  end

  def execute(tool_call, context, opts \\ []) do
    name = tool_name(tool_call)
    raw_arguments = tool_call["arguments"] || %{}

    with {:ok, tool} <- fetch_tool(name, opts, context, raw_arguments),
         {:ok, arguments} <- tool.normalize_arguments(raw_arguments, context),
         :ok <- pre_tool_use(tool, arguments, context),
         {:ok, result} <- tool.execute(arguments, context),
         {:ok, result} <- post_tool_use(tool, arguments, result, context) do
      {:ok, result}
    else
      {:error, reason} -> {:error, error_result(name, reason)}
    end
  end

  defp pre_tool_use(tool, arguments, context) do
    trace_tool_event(context, "preToolUse", tool.name(), "started", %{
      arguments: summarize_arguments(arguments)
    })

    case tool.authorize(arguments, context) do
      :ok ->
        trace_tool_event(context, "preToolUse", tool.name(), "completed", %{
          arguments: summarize_arguments(arguments)
        })

        :ok

      {:error, reason} ->
        trace_tool_event(context, "preToolUse", tool.name(), "failed", %{
          reason: inspect(reason),
          arguments: summarize_arguments(arguments)
        })

        {:error, reason}
    end
  end

  defp post_tool_use(tool, arguments, result, context) do
    trace_tool_event(context, "postToolUse", tool.name(), result_status(result), %{
      arguments: summarize_arguments(arguments),
      result: summarize_result(result)
    })

    {:ok, result}
  end

  def default_active_tools, do: @default_active_tools

  defp fetch_tool(name, opts, context, raw_arguments) when is_binary(name) and name != "" do
    tool =
      opts
      |> active_tool_modules()
      |> Enum.find(&(&1.name() == name))

    case tool do
      nil ->
        trace_tool_event(context, "preToolUse", name, "failed", %{
          reason: "tool_not_allowed",
          arguments: summarize_arguments(raw_arguments)
        })

        {:error, {:tool_not_allowed, name}}

      module ->
        {:ok, module}
    end
  end

  defp fetch_tool(name, _opts, context, raw_arguments) do
    trace_tool_event(context, "preToolUse", to_string(name || "unknown"), "failed", %{
      reason: "invalid_tool_name",
      arguments: summarize_arguments(raw_arguments)
    })

    {:error, {:invalid_tool_name, name}}
  end

  defp active_tool_modules(opts) do
    active_names = active_tool_names(opts)

    Enum.filter(@tools, fn tool ->
      active_names == :all or tool.name() in active_names
    end)
  end

  defp active_tool_names(opts) do
    case value(opts, :active_tools) || value(opts, :active_tool_names) do
      nil -> @default_active_tools
      names when is_list(names) -> Enum.filter(names, &is_binary/1)
      _names -> []
    end
  end

  defp tool_name(%{"name" => name}), do: name
  defp tool_name(%{"function" => %{"name" => name}}), do: name
  defp tool_name(_tool_call), do: nil

  defp error_result(name, reason) do
    code = error_code(reason)
    message = error_message(reason)

    %{
      "status" => "failed",
      "tool_name" => name,
      "error" => %{"code" => code, "message" => message},
      "error_code" => code
    }
  end

  defp result_status(%{"status" => status}) when is_binary(status), do: status
  defp result_status(_result), do: "completed"

  defp error_code({:tool_not_allowed, _name}), do: "tool_not_allowed"
  defp error_code({:invalid_tool_name, _name}), do: "invalid_tool_name"
  defp error_code(%{code: code}) when is_binary(code), do: code
  defp error_code(%{code: code}) when is_atom(code), do: Atom.to_string(code)
  defp error_code(%{"code" => code}) when is_binary(code), do: code
  defp error_code(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp error_code({code, _message}) when is_atom(code), do: Atom.to_string(code)
  defp error_code(_reason), do: "tool_failed"

  defp error_message({:tool_not_allowed, name}),
    do: "Tool #{name} is not allowed for AvcsAgent"

  defp error_message({:invalid_tool_name, name}),
    do: "Tool name is invalid: #{inspect(name)}"

  defp error_message(%{message: message}) when is_binary(message), do: message
  defp error_message(%{"message" => message}) when is_binary(message), do: message
  defp error_message({_code, message}) when is_binary(message), do: message
  defp error_message(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp error_message(reason) when is_binary(reason), do: reason
  defp error_message(reason), do: inspect(reason)

  defp trace_tool_event(context, event_name, tool_name, status, payload) do
    project = value(context, :project)

    if project do
      attrs = %{
        scope: "tool",
        event_name: event_name,
        thread_id: value(context, :thread_id),
        turn_id: value(context, :turn_id),
        agent_harness: "avcs_agent",
        provider: "vercel_ai_gateway",
        model: value(context, :model),
        remote_thread_id: value(context, :remote_thread_id),
        remote_turn_id: value(context, :remote_turn_id),
        remote_item_id: value(context, :tool_call_id),
        status: status,
        payload: Map.put(payload, :tool_name, tool_name)
      }

      case Avcs.Trace.append_event(project, attrs) do
        {:ok, _event} -> :ok
        _other -> :ok
      end
    end
  rescue
    exception ->
      Logger.warning(
        "Failed to append AvcsAgent tool trace event: #{Exception.message(exception)}"
      )

      :ok
  end

  defp summarize_arguments(arguments) when is_map(arguments) do
    Map.drop(arguments, [:base64, "base64", :b64_json, "b64_json"])
  end

  defp summarize_arguments(arguments), do: arguments

  defp summarize_result(%{"assets" => assets} = result) when is_list(assets) do
    result
    |> Map.take([
      "status",
      :status,
      "model",
      :model,
      "unsupported",
      :unsupported,
      "reference_count",
      :reference_count,
      "mask_asset_id",
      :mask_asset_id,
      "request",
      :request
    ])
    |> Map.put("asset_count", length(assets))
  end

  defp summarize_result(result) when is_map(result) do
    Map.take(result, ["status", :status, "error", :error, "error_code", :error_code])
  end

  defp summarize_result(result), do: result

  defp value(attrs, key) when is_list(attrs), do: Keyword.get(attrs, key)

  defp value(attrs, key) when is_map(attrs) do
    Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))
  end

  defp value(_attrs, _key), do: nil
end
