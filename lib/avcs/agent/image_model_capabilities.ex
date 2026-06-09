defmodule Avcs.Agent.ImageModelCapabilities do
  @moduledoc false

  def supports_reference_images?(base_url, model) do
    not vercel_image_api_only_model?(base_url, model)
  end

  def vercel_image_api_only_model?(base_url, model) do
    vercel_ai_gateway?(base_url) and openai_image_api_model?(model)
  end

  def vercel_ai_gateway?(base_url) when is_binary(base_url) do
    base_url
    |> String.downcase()
    |> String.contains?("ai-gateway.vercel.sh")
  end

  def vercel_ai_gateway?(_base_url), do: false

  def openai_image_api_model?(model) when is_binary(model) do
    model = String.downcase(model)

    String.contains?(model, "openai/gpt-image") or
      String.contains?(model, "openai/dall-e")
  end

  def openai_image_api_model?(_model), do: false
end
