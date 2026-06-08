defmodule Avcs.SiteSettings do
  @moduledoc """
  Global software settings stored in the user's Avcs data directory.

  These settings are software-level preferences. They live in the global
  SQLite database and must not be mixed with project business data.
  """

  alias Avcs.Storage.SQLite

  @setting_order [
    "agent.default_model",
    "agent.default_effort",
    "agent.default_approval_policy",
    "agent.default_sandbox_mode",
    "image.default_ratio",
    "image.default_count",
    "image.transparent_background",
    "projects.default_root",
    "projects.restore_last_opened",
    "assets.scan_on_open",
    "ui.locale"
  ]

  @defaults %{
    "agent.default_model" => "gpt-5.5",
    "agent.default_effort" => "medium",
    "agent.default_approval_policy" => "never",
    "agent.default_sandbox_mode" => "workspace-write",
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
  @valid_image_ratios ~w(auto 1:1 16:9 9:16 4:3 3:4 3:1 1:3)
  @valid_locales ~w(en zh-hans)

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
      {:ok, effective_value(key, stored[key])}
    end
  end

  def get_setting(_key), do: {:error, {:unknown_site_setting, nil}}

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
          model: normalize_optional_string(settings["agent.default_model"]),
          effort: normalize_optional_string(settings["agent.default_effort"]),
          approval_policy: settings["agent.default_approval_policy"] || "never",
          sandbox_mode: settings["agent.default_sandbox_mode"] || "workspace-write"
        }

      {:error, _reason} ->
        %{
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
    %{
      key: key,
      value: effective_value(key, row),
      default_value: Map.fetch!(@defaults, key),
      is_default: row == nil,
      updated_at: row && row["updated_at"]
    }
  end

  defp effective_value(key, nil), do: Map.fetch!(@defaults, key)

  defp effective_value(key, %{"value" => value}),
    do: decode_value(value, Map.fetch!(@defaults, key))

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

  defp normalize_setting("agent.default_approval_policy" = key, value) do
    normalize_member(key, value, @valid_approval_policies)
  end

  defp normalize_setting("agent.default_sandbox_mode" = key, value) do
    normalize_member(key, value, @valid_sandbox_modes)
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
end
