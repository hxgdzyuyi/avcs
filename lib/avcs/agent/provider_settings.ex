defmodule Avcs.Agent.ProviderSettings do
  @moduledoc false

  @vercel_ai_gateway_api_key "providers.vercel_ai_gateway.api_key"
  @vercel_ai_gateway_base_url "https://ai-gateway.vercel.sh/v1"

  def provider_setting_keys, do: [@vercel_ai_gateway_api_key]

  def provider_setting_changed?(keys) when is_list(keys) do
    Enum.any?(keys, &(to_string(&1) in provider_setting_keys()))
  end

  def provider_setting_changed?(_keys), do: false

  def app_server_env do
    case Avcs.SiteSettings.provider_runtime_settings() do
      %{vercel_ai_gateway_api_key: api_key} when is_binary(api_key) and api_key != "" ->
        [
          {"AI_GATEWAY_API_KEY", api_key},
          {"OPENAI_API_KEY", api_key},
          {"OPENAI_BASE_URL", @vercel_ai_gateway_base_url}
        ]

      _settings ->
        []
    end
  end

  def notify_settings_changed(keys) do
    if provider_setting_changed?(keys) do
      Avcs.Agent.CodexAppServerPool.provider_settings_changed()
    else
      :ok
    end
  rescue
    _exception -> :ok
  catch
    :exit, _reason -> :ok
  end
end
