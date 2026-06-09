defmodule Avcs.Agent.DataProvider do
  @moduledoc false

  @apod_slug "avcs-data-prodiver-apod"
  @apod_name "NASA APOD"
  @apod_version "0.1.0"
  @steam_slug "avcs-data-prodiver-steam"
  @steam_name "Steam Data Provider"
  @steam_version "0.1.0"

  def providers do
    [
      provider(@apod_slug),
      provider(@steam_slug)
    ]
  end

  def normalize(nil), do: {:ok, nil}
  def normalize(""), do: {:ok, nil}

  def normalize(%{} = payload) do
    slug = value(payload, "slug")

    with {:ok, config} <- provider_config(slug),
         :ok <- ensure_loaded(payload),
         :ok <- ensure_provider_files(config) do
      {:ok, public_provider(config)}
    end
  end

  def normalize(_payload), do: {:error, :invalid_data_provider}

  def provider_context(provider, items \\ [])

  def provider_context(nil, _items), do: nil

  def provider_context(provider, items) do
    case normalize(provider) do
      {:ok, nil} ->
        nil

      {:ok, normalized} ->
        base = %{
          "provider" => normalized,
          "status" => "selected"
        }

        case result_summary(normalized, items) do
          nil -> base
          summary -> Map.put(base, "result", summary)
        end

      {:error, reason} ->
        %{"status" => "invalid", "error" => to_string(reason)}
    end
  end

  def runner_instructions(_project, nil), do: nil

  def runner_instructions(project, provider) do
    with {:ok, normalized} <- normalize(provider) do
      """
      Data provider selected for this turn: #{normalized["name"]} (#{normalized["slug"]}).

      Execute this order before final image generation:
      1. Follow the injected data provider skill context for #{normalized["slug"]}; do not call `read` on the bundled skill path because file tools are limited to the current Avcs project.
      2. Fetch the provider source by calling the AvcsAgent `bash` tool with a data provider descriptor, not a shell command string:
         {"command_kind":"data_provider","provider":"#{normalized["slug"]}","args":{}}
      3. The `bash` tool runs the built-in provider script in a controlled backend allowlist and writes provider downloads only to `#{Avcs.Projects.work_dir(project)}`.
      4. If the tool result has `provider_status == "success"`, use `summary.image_path` / `asset_id` and key source fields from `summary`.
      5. If the provider returns `not_available` or `failed`, report the provider status and reason instead of inventing source data.
      6. If the configured image model transport supports references and the provider summary includes an image `asset_id`, pass that asset id to `image_gen` as `reference_asset_ids`. If the configured image model only supports text-to-image, use the provider summary fields in the prompt and call `image_gen` without references.
      7. After the provider data is available, write the provider summary fields into the image_gen prompt and write generated images to `#{Avcs.Projects.output_dir(project)}`.
      """
      |> String.trim()
    else
      _error -> nil
    end
  end

  def error_code(:unknown_data_provider), do: "unknown_data_provider"
  def error_code(:data_provider_not_loaded), do: "data_provider_not_loaded"
  def error_code(:data_provider_skill_missing), do: "data_provider_skill_missing"
  def error_code(:data_provider_script_missing), do: "data_provider_script_missing"
  def error_code(_reason), do: "invalid_data_provider"

  def error_message(:unknown_data_provider), do: "Data provider is not supported"
  def error_message(:data_provider_not_loaded), do: "Data provider must be loaded before sending"
  def error_message(:data_provider_skill_missing), do: "Data provider skill file is missing"
  def error_message(:data_provider_script_missing), do: "Data provider script is missing"
  def error_message(_reason), do: "Data provider payload is invalid"

  def provider_config(slug) do
    with {:ok, config} <- do_provider_config(slug) do
      {:ok, apply_script_override(config)}
    end
  end

  def normalize_slug("apod"), do: {:ok, @apod_slug}
  def normalize_slug("nasa_apod"), do: {:ok, @apod_slug}
  def normalize_slug(@apod_slug), do: {:ok, @apod_slug}
  def normalize_slug("steam"), do: {:ok, @steam_slug}
  def normalize_slug(@steam_slug), do: {:ok, @steam_slug}
  def normalize_slug(_slug), do: {:error, :unknown_data_provider}

  defp do_provider_config(@apod_slug), do: {:ok, provider(@apod_slug)}
  defp do_provider_config(@steam_slug), do: {:ok, provider(@steam_slug)}
  defp do_provider_config(_slug), do: {:error, :unknown_data_provider}

  defp provider(@apod_slug) do
    skill_dir = Path.join([priv_dir(), "skills", @apod_slug])

    %{
      slug: @apod_slug,
      name: @apod_name,
      version: @apod_version,
      skill_path: Path.join(skill_dir, "SKILL.md"),
      script_path: Path.join([skill_dir, "scripts", "fetch_apod.py"]),
      runner_args: " --prefer-hd"
    }
  end

  defp provider(@steam_slug) do
    skill_dir = Path.join([priv_dir(), "skills", @steam_slug])

    %{
      slug: @steam_slug,
      name: @steam_name,
      version: @steam_version,
      skill_path: Path.join(skill_dir, "SKILL.md"),
      script_path: Path.join([skill_dir, "scripts", "fetch_steam.py"]),
      runner_args: ""
    }
  end

  defp apply_script_override(config) do
    overrides = Application.get_env(:avcs, :data_provider_scripts, %{})
    override = Map.get(overrides, config.slug) || Map.get(overrides, to_string(config.slug))

    if is_binary(override) and override != "" do
      Map.put(config, :script_path, override)
    else
      config
    end
  end

  defp public_provider(config) do
    %{
      "slug" => config.slug,
      "name" => config.name,
      "version" => config.version,
      "loaded" => true
    }
  end

  defp ensure_loaded(payload) do
    case value(payload, "loaded") do
      true -> :ok
      "true" -> :ok
      _loaded -> {:error, :data_provider_not_loaded}
    end
  end

  defp ensure_provider_files(config) do
    cond do
      not File.exists?(config.skill_path) -> {:error, :data_provider_skill_missing}
      not File.exists?(config.script_path) -> {:error, :data_provider_script_missing}
      true -> :ok
    end
  end

  defp result_summary(provider, items) when is_list(items) do
    script_name = provider_script_name(provider)

    Enum.find_value(items, fn item ->
      cond do
        provider_bash_item?(item, provider["slug"]) ->
          provider_bash_output(item)

        provider_command_item?(item, provider["slug"], script_name) ->
          item
          |> output_text()
          |> decode_provider_output()

        true ->
          nil
      end
    end)
  end

  defp result_summary(_provider, _items), do: nil

  defp provider_command_item?(%{"type" => "commandExecution"} = item, slug, script_name) do
    command = item["command"] || item["cmd"] || item["text"] || ""
    String.contains?(command, slug) or String.contains?(command, script_name)
  end

  defp provider_command_item?(_item, _slug, _script_name), do: false

  defp provider_bash_item?(%{"name" => "bash", "result" => result}, slug) when is_map(result) do
    result["provider_slug"] == slug or result["provider"] == slug
  end

  defp provider_bash_item?(
         %{"tool_name" => "bash", "payload" => %{"remote_item" => remote}},
         slug
       )
       when is_map(remote) do
    provider_bash_item?(remote, slug)
  end

  defp provider_bash_item?(_item, _slug), do: false

  defp provider_bash_output(%{"result" => result}) when is_map(result) do
    result["summary"] ||
      provider_output_summary(result["provider_result"] || result["data"] || result)
  end

  defp provider_bash_output(_item), do: nil

  defp provider_script_name(%{"slug" => @apod_slug}), do: "fetch_apod.py"
  defp provider_script_name(%{"slug" => @steam_slug}), do: "fetch_steam.py"
  defp provider_script_name(_provider), do: ""

  defp output_text(item) do
    ["output", "stdout", "result", "text"]
    |> Enum.find_value(fn key ->
      case item[key] do
        value when is_binary(value) and value != "" -> value
        _value -> nil
      end
    end)
  end

  defp decode_provider_output(nil), do: nil

  defp decode_provider_output(output) do
    output
    |> String.trim()
    |> Jason.decode()
    |> case do
      {:ok, %{} = decoded} -> provider_output_summary(decoded)
      _error -> nil
    end
  end

  defp provider_output_summary(%{"data" => data} = payload) when is_map(data) do
    %{
      "status" => payload["status"],
      "reason" => payload["reason"],
      "date" => data["date"],
      "title" => data["title"] || data["name"],
      "media_type" => data["media_type"],
      "source" => data["source"],
      "image_path" => data["image_path"],
      "apod_url" => data["apod_url"] || data["url"],
      "store_url" => data["store_url"],
      "appid" => data["appid"],
      "copyright" => data["copyright"]
    }
    |> reject_blank_values()
  end

  defp provider_output_summary(payload) do
    %{
      "status" => payload["status"],
      "reason" => payload["reason"],
      "error" => payload["error"]
    }
    |> reject_blank_values()
  end

  defp reject_blank_values(map) do
    map
    |> Enum.reject(fn {_key, value} -> is_nil(value) or value == "" end)
    |> Map.new()
  end

  defp value(attrs, key) do
    Map.get(attrs, key) || Map.get(attrs, String.to_atom(key))
  rescue
    ArgumentError -> Map.get(attrs, key)
  end

  defp priv_dir do
    case :code.priv_dir(:avcs) do
      path when is_list(path) -> List.to_string(path)
      {:error, _reason} -> Path.expand("priv", File.cwd!())
    end
  end
end
