defmodule Avcs.Agent.ImageModelCapabilities do
  @moduledoc false

  def supports_reference_images?(base_url, model) do
    if vercel_ai_gateway?(base_url) do
      vercel_chat_completions_image_model?(base_url, model)
    else
      true
    end
  end

  def vercel_chat_completions_image_model?(base_url, model) do
    vercel_ai_gateway?(base_url) and gemini_image_model?(model)
  end

  def vercel_image_api_only_model?(base_url, model) do
    vercel_ai_gateway?(base_url) and image_api_only_model?(model)
  end

  def vercel_ai_gateway?(base_url) when is_binary(base_url) do
    base_url
    |> String.downcase()
    |> String.contains?("ai-gateway.vercel.sh")
  end

  def vercel_ai_gateway?(_base_url), do: false

  def image_api_only_model?(model) when is_binary(model) do
    model = String.downcase(model)

    String.contains?(model, "openai/gpt-image") or
      String.contains?(model, "openai/dall-e") or
      String.contains?(model, "imagen") or
      String.contains?(model, "flux") or
      (String.contains?(model, "grok") and String.contains?(model, "image"))
  end

  def image_api_only_model?(_model), do: false

  defp gemini_image_model?(model) when is_binary(model) do
    model = String.downcase(model)

    String.contains?(model, "gemini") and String.contains?(model, "image")
  end

  defp gemini_image_model?(_model), do: false
end
