defmodule Avcs.SiteSettings do
  @moduledoc """
  Global software settings stored in the user's Avcs data directory.

  These settings are software-level preferences. They live in the global
  SQLite database and must not be mixed with project business data.
  """

  alias Avcs.Storage.SQLite

  @setting_order [
    "agent.harness",
    "agent.default_model",
    "agent.default_effort",
    "agent.default_approval_policy",
    "agent.default_sandbox_mode",
    "agent.avcs_agent.base_url",
    "agent.avcs_agent.text_model",
    "agent.avcs_agent.image_model",
    "agent.avcs_agent.max_tool_steps",
    "agent.avcs_agent.compact_threshold",
    "providers.vercel_ai_gateway.api_key",
    "image.default_ratio",
    "image.default_count",
    "image.transparent_background",
    "projects.default_root",
    "projects.restore_last_opened",
    "assets.scan_on_open",
    "ui.locale"
  ]

  @defaults %{
    "agent.harness" => "codex",
    "agent.default_model" => "gpt-5.5",
    "agent.default_effort" => "medium",
    "agent.default_approval_policy" => "never",
    "agent.default_sandbox_mode" => "workspace-write",
    "agent.avcs_agent.base_url" => "https://ai-gateway.vercel.sh/v1",
    "agent.avcs_agent.text_model" => "deepseek/deepseek-v4-pro",
    "agent.avcs_agent.image_model" => "openai/gpt-image-2",
    "agent.avcs_agent.max_tool_steps" => 3,
    "agent.avcs_agent.compact_threshold" => 0.75,
    "providers.vercel_ai_gateway.api_key" => nil,
    "image.default_ratio" => "auto",
    "image.default_count" => 1,
    "image.transparent_background" => false,
    "projects.default_root" => "~/Documents/Avcs",
    "projects.restore_last_opened" => true,
    "assets.scan_on_open" => false,
    "ui.locale" => "en"
  }

  @valid_efforts ~w(none minimal low medium high xhigh)
  @valid_approval_policies ~w(never untrusted on-failure on-request)
  @valid_sandbox_modes ~w(read-only workspace-write danger-full-access)
  @valid_harnesses ~w(auto codex avcs_agent)
  @valid_image_ratios ~w(auto 1:1 16:9 9:16 4:3 3:4 3:1 1:3)
  @valid_locales ~w(en zh-hans)
  @secret_keys [
    "providers.vercel_ai_gateway.api_key"
  ]

  def keys, do: @setting_order
  def defaults, do: @defaults

  def list_settings do
    with {:ok, rows} <- stored_settings() do
      stored = Map.new(rows, &{&1["key"], &1})
      {:ok, Enum.map(@setting_order, &setting_item(&1, stored[&1]))}
    end
  end

  def get_setting(key) when is_binary(key) do
    with :ok <- ensure_registered(key),
         {:ok, rows} <- stored_settings() do
      stored = Map.new(rows, &{&1["key"], &1})
      {:ok, public_value(key, stored[key])}
    end
  end

  def get_setting(_key), do: {:error, {:unknown_site_setting, nil}}

  def secret_value(key) when is_binary(key) do
    with :ok <- ensure_registered(key),
         :ok <- ensure_secret(key),
         {:ok, rows} <- stored_settings() do
      stored = Map.new(rows, &{&1["key"], &1})
      {:ok, secret_effective_value(key, stored[key])}
    end
  end

  def secret_value(_key), do: {:error, {:unknown_site_setting, nil}}

  def provider_runtime_settings do
    {:ok, api_key} = secret_value("providers.vercel_ai_gateway.api_key")

    %{
      vercel_ai_gateway_api_key: normalize_optional_string(api_key)
    }
  rescue
    _exception ->
      %{vercel_ai_gateway_api_key: nil}
  end

  def avcs_agent_runtime_settings do
    settings =
      case effective_settings() do
        {:ok, settings} -> settings
        {:error, _reason} -> @defaults
      end

    {:ok, api_key} = secret_value("providers.vercel_ai_gateway.api_key")

    %{
      harness: settings["agent.harness"] || @defaults["agent.harness"],
      base_url:
        normalize_optional_string(settings["agent.avcs_agent.base_url"]) ||
          @defaults["agent.avcs_agent.base_url"],
      api_key: normalize_optional_string(api_key),
      text_model:
        normalize_optional_string(settings["agent.avcs_agent.text_model"]) ||
          @defaults["agent.avcs_agent.text_model"],
      image_model:
        normalize_optional_string(settings["agent.avcs_agent.image_model"]) ||
          @defaults["agent.avcs_agent.image_model"],
      max_tool_steps:
        normalize_positive_integer(
          settings["agent.avcs_agent.max_tool_steps"],
          @defaults["agent.avcs_agent.max_tool_steps"]
        ),
      compact_threshold:
        normalize_float_between(
          settings["agent.avcs_agent.compact_threshold"],
          @defaults["agent.avcs_agent.compact_threshold"],
          0.1,
          0.95
        )
    }
  rescue
    _exception ->
      %{
        harness: @defaults["agent.harness"],
        base_url: @defaults["agent.avcs_agent.base_url"],
        api_key: nil,
        text_model: @defaults["agent.avcs_agent.text_model"],
        image_model: @defaults["agent.avcs_agent.image_model"],
        max_tool_steps: @defaults["agent.avcs_agent.max_tool_steps"],
        compact_threshold: @defaults["agent.avcs_agent.compact_threshold"]
      }
  end

  def secret_key?(key), do: key in @secret_keys

  def effective_settings do
    with {:ok, items} <- list_settings() do
      {:ok, Map.new(items, &{&1.key, &1.value})}
    end
  end

  def update_settings(%{"settings" => settings}), do: update_settings(settings)
  def update_settings(%{settings: settings}), do: update_settings(settings)

  def update_settings(settings) when is_map(settings) do
    with {:ok, normalized_settings} <- normalize_settings(settings),
         {:ok, rows} <-
           SQLite.with_db(Avcs.Projects.global_db_path(), fn db ->
             ensure_table!(db)

             SQLite.transaction!(db, fn ->
               now = Avcs.Time.now_iso()

               Enum.each(normalized_settings, fn {key, value} ->
                 SQLite.run!(
                   db,
                   """
                   INSERT INTO app_settings (key, value, updated_at)
                   VALUES (?, ?, ?)
                   ON CONFLICT(key) DO UPDATE SET
                     value = excluded.value,
                     updated_at = excluded.updated_at
                   """,
                   [key, Jason.encode!(value), now]
                 )
               end)

               fetch_rows!(db)
             end)
           end) do
      {:ok, response_from_rows(rows)}
    end
  end

  def update_settings(_settings), do: {:error, {:invalid_site_setting, nil}}

  def reset_setting(key), do: reset_settings([key])

  def reset_settings(%{"keys" => keys}), do: reset_settings(keys)
  def reset_settings(%{keys: keys}), do: reset_settings(keys)

  def reset_settings(keys) when is_list(keys) do
    with {:ok, clean_keys} <- normalize_keys(keys),
         {:ok, rows} <-
           SQLite.with_db(Avcs.Projects.global_db_path(), fn db ->
             ensure_table!(db)

             SQLite.transaction!(db, fn ->
               Enum.each(clean_keys, fn key ->
                 SQLite.run!(db, "DELETE FROM app_settings WHERE key = ?", [key])
               end)

               fetch_rows!(db)
             end)
           end) do
      {:ok, response_from_rows(rows)}
    end
  end

  def reset_settings(_keys), do: {:error, {:invalid_site_setting, nil}}

  def agent_defaults do
    case effective_settings() do
      {:ok, settings} ->
        %{
          harness: settings["agent.harness"] || @defaults["agent.harness"],
          model: normalize_optional_string(settings["agent.default_model"]),
          effort: normalize_optional_string(settings["agent.default_effort"]),
          approval_policy: settings["agent.default_approval_policy"] || "never",
          sandbox_mode: settings["agent.default_sandbox_mode"] || "workspace-write"
        }

      {:error, _reason} ->
        %{
          harness: @defaults["agent.harness"],
          model: @defaults["agent.default_model"],
          effort: @defaults["agent.default_effort"],
          approval_policy: "never",
          sandbox_mode: "workspace-write"
        }
    end
  end

  def ensure_table!(db) do
    SQLite.exec!(db, """
    CREATE TABLE IF NOT EXISTS app_settings (
      key TEXT PRIMARY KEY,
      value TEXT NOT NULL,
      updated_at TEXT NOT NULL
    );
    """)
  end

  def error_code({:unknown_site_setting, _key}), do: "unknown_site_setting"
  def error_code({:invalid_site_setting, _key}), do: "invalid_site_setting"
  def error_code(_reason), do: "site_settings_update_failed"

  def error_message({:unknown_site_setting, key}) when is_binary(key),
    do: "Unknown site setting: #{key}"

  def error_message({:unknown_site_setting, _key}), do: "Unknown site setting"

  def error_message({:invalid_site_setting, key}) when is_binary(key),
    do: "Invalid site setting: #{key}"

  def error_message({:invalid_site_setting, _key}), do: "Invalid site setting"
  def error_message(reason), do: to_string(reason)

  def error_details({:unknown_site_setting, key}) when is_binary(key), do: %{key: key}
  def error_details({:invalid_site_setting, key}) when is_binary(key), do: %{key: key}
  def error_details(_reason), do: nil

  defp stored_settings do
    with {:ok, _} <- Avcs.Projects.migrate_global_db() do
      SQLite.with_db(Avcs.Projects.global_db_path(), fn db ->
        ensure_table!(db)
        fetch_rows!(db)
      end)
    end
  end

  defp fetch_rows!(db) do
    SQLite.all!(
      db,
      """
      SELECT key, value, updated_at
      FROM app_settings
      ORDER BY key ASC
      """
    )
  end

  defp response_from_rows(rows) do
    stored = Map.new(rows, &{&1["key"], &1})
    items = Enum.map(@setting_order, &setting_item(&1, stored[&1]))

    %{
      items: items,
      settings: Map.new(items, &{&1.key, &1.value})
    }
  end

  defp setting_item(key, row) do
    if secret_key?(key) do
      secret_setting_item(key, row)
    else
      %{
        key: key,
        value: effective_value(key, row),
        default_value: Map.fetch!(@defaults, key),
        is_default: row == nil,
        updated_at: row && row["updated_at"]
      }
    end
  end

  defp secret_setting_item(key, row) do
    secret_value = secret_effective_value(key, row)
    has_value = is_binary(secret_value) and secret_value != ""

    %{
      key: key,
      value: nil,
      default_value: nil,
      is_default: not has_value,
      updated_at: row && row["updated_at"],
      is_secret: true,
      has_value: has_value,
      masked_value: masked_secret(secret_value)
    }
  end

  defp effective_value(key, nil), do: Map.fetch!(@defaults, key)

  defp effective_value(key, %{"value" => value}),
    do: decode_value(value, Map.fetch!(@defaults, key))

  defp public_value(key, row) do
    if secret_key?(key) do
      nil
    else
      effective_value(key, row)
    end
  end

  defp secret_effective_value(_key, nil), do: nil

  defp secret_effective_value(key, %{"value" => value}) do
    value
    |> decode_value(Map.fetch!(@defaults, key))
    |> normalize_optional_string()
  end

  defp masked_secret(value) when is_binary(value) and value != "" do
    suffix =
      value
      |> String.slice(-4, 4)
      |> to_string()

    "****" <> suffix
  end

  defp masked_secret(_value), do: nil

  defp decode_value(value, fallback) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} -> decoded
      {:error, _reason} -> fallback
    end
  end

  defp decode_value(_value, fallback), do: fallback

  defp normalize_keys(keys) do
    keys
    |> Enum.reduce_while({:ok, []}, fn key, {:ok, acc} ->
      key = to_string(key)

      case ensure_registered(key) do
        :ok -> {:cont, {:ok, [key | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, clean_keys} -> {:ok, clean_keys |> Enum.reverse() |> Enum.uniq()}
      error -> error
    end
  end

  defp normalize_settings(settings) do
    settings
    |> Enum.reduce_while({:ok, []}, fn {key, value}, {:ok, acc} ->
      key = to_string(key)

      with :ok <- ensure_registered(key),
           {:ok, clean_value} <- normalize_setting(key, value) do
        {:cont, {:ok, [{key, clean_value} | acc]}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, clean_settings} -> {:ok, Enum.reverse(clean_settings)}
      error -> error
    end
  end

  defp ensure_registered(key) when is_binary(key) do
    if Map.has_key?(@defaults, key) do
      :ok
    else
      {:error, {:unknown_site_setting, key}}
    end
  end

  defp ensure_secret(key) do
    if secret_key?(key) do
      :ok
    else
      {:error, {:unknown_site_setting, key}}
    end
  end

  defp normalize_setting("agent.harness" = key, value) do
    normalize_member(key, value, @valid_harnesses)
  end

  defp normalize_setting("agent.default_model" = key, value) do
    case normalize_optional_string(value) do
      nil -> {:ok, nil}
      clean -> {:ok, clean}
    end
  rescue
    _exception -> {:error, {:invalid_site_setting, key}}
  end

  defp normalize_setting("agent.default_effort" = key, value) do
    value = normalize_optional_string(value)

    cond do
      value == nil -> {:ok, nil}
      value in @valid_efforts -> {:ok, value}
      true -> {:error, {:invalid_site_setting, key}}
    end
  end

  defp normalize_setting("providers.vercel_ai_gateway.api_key" = key, value) do
    case normalize_optional_string(value) do
      nil -> {:error, {:invalid_site_setting, key}}
      clean -> {:ok, clean}
    end
  rescue
    _exception -> {:error, {:invalid_site_setting, key}}
  end

  defp normalize_setting("agent.default_approval_policy" = key, value) do
    normalize_member(key, value, @valid_approval_policies)
  end

  defp normalize_setting("agent.default_sandbox_mode" = key, value) do
    normalize_member(key, value, @valid_sandbox_modes)
  end

  defp normalize_setting("agent.avcs_agent.base_url" = key, value) do
    case normalize_optional_string(value) do
      "http://" <> _rest = url -> {:ok, String.trim_trailing(url, "/")}
      "https://" <> _rest = url -> {:ok, String.trim_trailing(url, "/")}
      _value -> {:error, {:invalid_site_setting, key}}
    end
  end

  defp normalize_setting(key, value)
       when key in ["agent.avcs_agent.text_model", "agent.avcs_agent.image_model"] do
    case normalize_optional_string(value) do
      nil -> {:error, {:invalid_site_setting, key}}
      clean -> {:ok, clean}
    end
  end

  defp normalize_setting("agent.avcs_agent.max_tool_steps" = key, value) do
    steps = normalize_positive_integer(value, nil)

    if is_integer(steps) and steps >= 1 and steps <= 10 do
      {:ok, steps}
    else
      {:error, {:invalid_site_setting, key}}
    end
  end

  defp normalize_setting("agent.avcs_agent.compact_threshold" = key, value) do
    threshold = normalize_float_between(value, nil, 0.1, 0.95)

    if is_float(threshold) do
      {:ok, threshold}
    else
      {:error, {:invalid_site_setting, key}}
    end
  end

  defp normalize_setting("image.default_ratio" = key, value) do
    normalize_member(key, value, @valid_image_ratios)
  end

  defp normalize_setting("image.default_count" = key, value) do
    count =
      cond do
        is_integer(value) ->
          value

        is_binary(value) ->
          case Integer.parse(String.trim(value)) do
            {integer, ""} -> integer
            _other -> nil
          end

        true ->
          nil
      end

    if is_integer(count) and count >= 1 and count <= 4 do
      {:ok, count}
    else
      {:error, {:invalid_site_setting, key}}
    end
  end

  defp normalize_setting(key, value)
       when key in [
              "image.transparent_background",
              "projects.restore_last_opened",
              "assets.scan_on_open"
            ] do
    case normalize_boolean(value) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, {:invalid_site_setting, key}}
    end
  end

  defp normalize_setting("projects.default_root" = key, value) do
    path = normalize_optional_string(value)

    if path do
      {:ok, Path.expand(path)}
    else
      {:error, {:invalid_site_setting, key}}
    end
  end

  defp normalize_setting("ui.locale" = key, value) do
    normalize_member(key, value, @valid_locales)
  end

  defp normalize_member(key, value, valid_values) do
    value = normalize_optional_string(value)

    if value in valid_values do
      {:ok, value}
    else
      {:error, {:invalid_site_setting, key}}
    end
  end

  defp normalize_optional_string(nil), do: nil

  defp normalize_optional_string(value) do
    value
    |> to_string()
    |> String.trim()
    |> case do
      "" -> nil
      clean -> clean
    end
  end

  defp normalize_boolean(value) when is_boolean(value), do: {:ok, value}
  defp normalize_boolean("true"), do: {:ok, true}
  defp normalize_boolean("false"), do: {:ok, false}
  defp normalize_boolean(_value), do: :error

  defp normalize_positive_integer(value, _fallback) when is_integer(value) and value > 0,
    do: value

  defp normalize_positive_integer(value, fallback) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {integer, ""} when integer > 0 -> integer
      _other -> fallback
    end
  end

  defp normalize_positive_integer(_value, fallback), do: fallback

  defp normalize_float_between(value, fallback, min, max) do
    number =
      cond do
        is_float(value) -> value
        is_integer(value) -> value * 1.0
        is_binary(value) -> parse_float(value)
        true -> nil
      end

    if is_float(number) and number >= min and number <= max do
      number
    else
      fallback
    end
  end

  defp parse_float(value) do
    case Float.parse(String.trim(value)) do
      {number, ""} -> number
      _other -> nil
    end
  end
end
