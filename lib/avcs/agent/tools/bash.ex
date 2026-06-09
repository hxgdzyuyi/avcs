defmodule Avcs.Agent.Tools.Bash do
  @moduledoc false

  @behaviour Avcs.Agent.Tool

  alias Avcs.Agent.Tools.ProjectFile

  @timeout_ms 35_000
  @summary_bytes 2_000
  @cover_keys ~w(header_image capsule_image capsule_imagev5 any last)

  @impl true
  def name, do: "bash"

  @impl true
  def description do
    "Run an Avcs controlled data provider command. This is not a shell: arbitrary command strings, pipes, redirects, and non-allowlisted commands are rejected."
  end

  @impl true
  def parameters_schema do
    %{
      "type" => "object",
      "properties" => %{
        "command_kind" => %{"type" => "string", "enum" => ["data_provider"]},
        "provider" => %{
          "type" => "string",
          "enum" => [
            "apod",
            "nasa_apod",
            "avcs-data-prodiver-apod",
            "steam",
            "avcs-data-prodiver-steam"
          ]
        },
        "args" => %{"type" => "object"}
      },
      "required" => ["command_kind", "provider"]
    }
  end

  @impl true
  def normalize_arguments(arguments, _context) do
    with {:ok, arguments} <- ProjectFile.decode_arguments(arguments),
         {:ok, command_kind} <- normalize_command_kind(arguments),
         {:ok, provider_slug} <-
           normalize_provider(ProjectFile.string_arg(arguments, "provider")),
         {:ok, provider_args} <- normalize_provider_args(provider_slug, provider_args(arguments)) do
      {:ok,
       %{
         command_kind: command_kind,
         provider: provider_short_name(provider_slug),
         provider_slug: provider_slug,
         args: provider_args
       }}
    end
  end

  @impl true
  def authorize(args, context) do
    project = ProjectFile.value(context, :project)

    with :ok <- ensure_project(project),
         {:ok, _work_info} <-
           ProjectFile.resolve_existing(project, Avcs.Projects.work_dir(project),
             kind: :directory,
             scopes: [:work]
           ),
         {:ok, config} <- Avcs.Agent.DataProvider.provider_config(args.provider_slug),
         :ok <- ensure_provider_files(config),
         {:ok, _python} <- python_executable() do
      :ok
    else
      {:error, :unknown_data_provider} ->
        {:error, ProjectFile.error(:unknown_data_provider, "Data provider is not supported")}

      {:error, reason} when is_atom(reason) ->
        {:error, ProjectFile.error(reason, Avcs.Agent.DataProvider.error_message(reason))}

      other ->
        other
    end
  end

  @impl true
  def execute(args, context) do
    project = ProjectFile.value(context, :project)

    with :ok <- ensure_project(project),
         root <- Avcs.Projects.folder_path(project),
         work_dir <- Avcs.Projects.work_dir(project),
         {:ok, config} <- Avcs.Agent.DataProvider.provider_config(args.provider_slug),
         {:ok, python} <- python_executable(),
         argv <- provider_argv(config, work_dir, args),
         started_at <- System.monotonic_time(:millisecond),
         run <- run_provider(python, [config.script_path | argv], root),
         duration_ms <- System.monotonic_time(:millisecond) - started_at,
         trace_provider_command(context, args, run, duration_ms),
         :ok <- ensure_provider_completed(run),
         {:ok, provider_result} <- decode_provider_result(run.stdout),
         {:ok, asset} <- maybe_register_provider_asset(project, provider_result, context),
         summary <- provider_summary(provider_result, asset) do
      {:ok,
       %{
         "status" => "completed",
         "command_kind" => "data_provider",
         "provider" => args.provider,
         "provider_slug" => args.provider_slug,
         "provider_status" => provider_result["status"],
         "exit_status" => run.exit_status,
         "duration_ms" => duration_ms,
         "asset_id" => asset && asset["id"],
         "image_path" => summary["image_path"],
         "relative_path" => asset && asset["relative_path"],
         "title" => summary["title"],
         "date" => summary["date"],
         "explanation" => summary["explanation"],
         "copyright" => summary["copyright"],
         "summary" => summary,
         "provider_result" => summarize_provider_result(provider_result)
       }
       |> reject_blank_values()}
    else
      {:error, :unknown_data_provider} ->
        {:error, ProjectFile.error(:unknown_data_provider, "Data provider is not supported")}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_command_kind(arguments) do
    kind =
      ProjectFile.string_arg(arguments, "command_kind") ||
        ProjectFile.string_arg(arguments, "kind") ||
        ProjectFile.string_arg(arguments, "command")

    cond do
      kind in [nil, ""] and ProjectFile.string_arg(arguments, "provider") ->
        {:ok, "data_provider"}

      kind == "data_provider" ->
        {:ok, "data_provider"}

      true ->
        {:error,
         ProjectFile.error(
           :command_not_allowed,
           "bash only accepts the data_provider command descriptor"
         )}
    end
  end

  defp normalize_provider(provider) do
    case Avcs.Agent.DataProvider.normalize_slug(provider) do
      {:ok, slug} ->
        {:ok, slug}

      {:error, _reason} ->
        {:error, ProjectFile.error(:unknown_data_provider, "Data provider is not supported")}
    end
  end

  defp provider_args(arguments) do
    case ProjectFile.value(arguments, "args") do
      args when is_map(args) -> args
      nil -> %{}
      _args -> %{}
    end
  end

  defp normalize_provider_args("avcs-data-prodiver-apod", args) do
    if ProjectFile.value(args, "api_key") || ProjectFile.value(args, "api-key") do
      {:error,
       ProjectFile.error(
         :secret_argument_denied,
         "Provider API keys are not accepted in tool arguments"
       )}
    else
      {:ok,
       %{
         date: normalize_date(ProjectFile.string_arg(args, "date")),
         prefer_hd: ProjectFile.boolean_arg(args, "prefer_hd", false)
       }
       |> reject_nil_values()}
    end
  end

  defp normalize_provider_args("avcs-data-prodiver-steam", args) do
    game = ProjectFile.string_arg(args, "game")

    if is_nil(game) do
      {:error,
       ProjectFile.error(:provider_argument_required, "Steam provider requires args.game")}
    else
      cover_key = ProjectFile.string_arg(args, "cover_key", "header_image")
      cover_key = if cover_key in @cover_keys, do: cover_key, else: "header_image"

      {:ok,
       %{
         game: game,
         lang: ProjectFile.string_arg(args, "lang", "en-us"),
         cc: ProjectFile.string_arg(args, "cc", "US"),
         cover_key: cover_key,
         select_index: ProjectFile.integer_arg(args, "select_index", 0, 0, 50)
       }}
    end
  end

  defp normalize_provider_args(_provider, _args),
    do: {:error, ProjectFile.error(:unknown_data_provider, "Data provider is not supported")}

  defp normalize_date(nil), do: nil

  defp normalize_date(date) do
    if String.match?(date, ~r/^\d{4}-\d{2}-\d{2}$/), do: date
  end

  defp provider_argv(_config, work_dir, %{provider_slug: "avcs-data-prodiver-apod", args: args}) do
    ["--out-dir", work_dir]
    |> put_optional_arg("--date", args[:date])
    |> put_flag("--prefer-hd", Map.get(args, :prefer_hd, false))
  end

  defp provider_argv(_config, work_dir, %{provider_slug: "avcs-data-prodiver-steam", args: args}) do
    [
      "--out-dir",
      work_dir,
      "--game",
      args.game,
      "--lang",
      args.lang,
      "--cc",
      args.cc,
      "--cover-key",
      args.cover_key,
      "--select-index",
      to_string(args.select_index)
    ]
  end

  defp put_optional_arg(argv, _name, nil), do: argv
  defp put_optional_arg(argv, name, value), do: argv ++ [name, value]

  defp put_flag(argv, name, true), do: argv ++ [name]
  defp put_flag(argv, _name, _value), do: argv

  defp run_provider(python, argv, cwd) do
    task =
      Task.async(fn ->
        {stdout, status} = System.cmd(python, argv, cd: cwd, stderr_to_stdout: true)
        %{stdout: stdout, stderr: "", exit_status: status, timed_out?: false}
      end)

    case Task.yield(task, provider_timeout_ms()) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} ->
        result

      nil ->
        %{stdout: "", stderr: "", exit_status: nil, timed_out?: true}

      _other ->
        %{stdout: "", stderr: "", exit_status: nil, timed_out?: true}
    end
  end

  defp ensure_provider_completed(%{timed_out?: true}) do
    {:error,
     ProjectFile.error(
       :provider_timeout,
       "Data provider timed out before returning JSON",
       "Timed out after #{provider_timeout_ms()}ms"
     )}
  end

  defp ensure_provider_completed(_run), do: :ok

  defp decode_provider_result(stdout) do
    stdout
    |> to_string()
    |> String.trim()
    |> Jason.decode()
    |> case do
      {:ok, %{} = decoded} ->
        {:ok, decoded}

      {:error, reason} ->
        {:error,
         ProjectFile.error(
           :provider_json_invalid,
           "Provider did not return a valid JSON object",
           Exception.message(reason)
         )}

      _other ->
        {:error,
         ProjectFile.error(:provider_json_invalid, "Provider result must be a JSON object")}
    end
  end

  defp maybe_register_provider_asset(project, %{"status" => "success", "data" => data}, context)
       when is_map(data) do
    case data["image_path"] do
      path when is_binary(path) and path != "" ->
        with {:ok, info} <-
               ProjectFile.resolve_existing(project, path, kind: :file, scopes: [:work]),
             {:ok, asset} <-
               ProjectFile.upsert_image_if_supported(project, info.path, context, "provider") do
          {:ok, asset}
        else
          {:ok, nil} ->
            {:error,
             ProjectFile.error(
               :provider_output_not_image,
               "Provider image_path is not a supported image"
             )}

          {:error, reason} ->
            {:error, reason}
        end

      _path ->
        {:ok, nil}
    end
  end

  defp maybe_register_provider_asset(_project, _provider_result, _context), do: {:ok, nil}

  defp provider_summary(%{"data" => data} = payload, asset) when is_map(data) do
    %{
      "status" => payload["status"],
      "reason" => payload["reason"],
      "error" => payload["error"],
      "asset_id" => asset && asset["id"],
      "relative_path" => asset && asset["relative_path"],
      "image_path" => data["image_path"],
      "title" => data["title"] || data["name"],
      "date" => data["date"] || data["release_date"],
      "explanation" => data["explanation"] || data["short_description"],
      "copyright" => data["copyright"],
      "source" => data["source"],
      "media_type" => data["media_type"],
      "apod_url" => data["apod_url"] || data["url"],
      "store_url" => data["store_url"],
      "appid" => data["appid"]
    }
    |> reject_blank_values()
  end

  defp provider_summary(payload, _asset) do
    %{
      "status" => payload["status"],
      "reason" => payload["reason"],
      "error" => payload["error"]
    }
    |> reject_blank_values()
  end

  defp summarize_provider_result(result) do
    result
    |> trim_deep_strings()
    |> reject_blank_values()
  end

  defp trim_deep_strings(value) when is_map(value) do
    value
    |> Enum.map(fn {key, child} -> {key, trim_deep_strings(child)} end)
    |> Map.new()
  end

  defp trim_deep_strings(value) when is_list(value), do: Enum.map(value, &trim_deep_strings/1)

  defp trim_deep_strings(value) when is_binary(value) do
    if byte_size(value) > @summary_bytes do
      String.slice(value, 0, @summary_bytes) <> "\n[truncated]"
    else
      value
    end
  end

  defp trim_deep_strings(value), do: value

  defp trace_provider_command(context, args, run, duration_ms) do
    project = ProjectFile.value(context, :project)

    if project do
      Avcs.Trace.append_event(project, %{
        scope: "tool",
        event_name: "bash_command",
        thread_id: ProjectFile.value(context, :thread_id),
        turn_id: ProjectFile.value(context, :turn_id),
        agent_harness: "avcs_agent",
        provider: "local",
        model: ProjectFile.value(context, :model),
        remote_thread_id: ProjectFile.value(context, :remote_thread_id),
        remote_turn_id: ProjectFile.value(context, :remote_turn_id),
        remote_item_id: ProjectFile.value(context, :tool_call_id),
        status: if(run.timed_out?, do: "failed", else: "completed"),
        payload: %{
          tool_name: "bash",
          command_kind: args.command_kind,
          provider: args.provider,
          provider_slug: args.provider_slug,
          args: summarize_args(args.args),
          exit_status: run.exit_status,
          duration_ms: duration_ms,
          timed_out: run.timed_out?,
          stdout_summary: summarize_output(run.stdout),
          stderr_summary: summarize_output(run.stderr)
        }
      })
    end

    :ok
  rescue
    _exception -> :ok
  end

  defp summarize_args(args) do
    args
    |> Enum.reject(fn {key, _value} ->
      key
      |> to_string()
      |> String.match?(~r/(secret|token|api[_-]?key|password)/i)
    end)
    |> Map.new()
  end

  defp summarize_output(output) do
    output
    |> to_string()
    |> String.replace(~r/(api[_-]?key|token|password|secret)=\S+/i, "\\1=[redacted]")
    |> String.slice(0, @summary_bytes)
  end

  defp ensure_provider_files(config) do
    cond do
      not File.exists?(config.skill_path) -> {:error, :data_provider_skill_missing}
      not File.exists?(config.script_path) -> {:error, :data_provider_script_missing}
      true -> :ok
    end
  end

  defp ensure_project(nil),
    do: {:error, ProjectFile.error(:project_required, "Current Avcs project is required")}

  defp ensure_project(_project), do: :ok

  defp python_executable do
    cond do
      python = System.find_executable("python3") -> {:ok, python}
      python = System.find_executable("python") -> {:ok, python}
      true -> {:error, ProjectFile.error(:python_unavailable, "Python is unavailable")}
    end
  end

  defp provider_timeout_ms do
    Application.get_env(:avcs, :data_provider_timeout_ms, @timeout_ms)
  end

  defp provider_short_name("avcs-data-prodiver-apod"), do: "apod"
  defp provider_short_name("avcs-data-prodiver-steam"), do: "steam"

  defp reject_nil_values(map) do
    map
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp reject_blank_values(map) do
    map
    |> Enum.reject(fn {_key, value} -> value in [nil, "", [], %{}] end)
    |> Map.new()
  end
end
