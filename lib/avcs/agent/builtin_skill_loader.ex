defmodule Avcs.Agent.BuiltinSkillLoader do
  @moduledoc false

  @builtin_skills %{
    "avcs-imagegen-avcs-agent" => "avcs-imagegen-avcs-agent/SKILL.md",
    "avcs-imagegen-codex" => "avcs-imagegen-codex/SKILL.md",
    "avcs-data-prodiver-apod" => "avcs-data-prodiver-apod/SKILL.md",
    "avcs-data-prodiver-steam" => "avcs-data-prodiver-steam/SKILL.md"
  }

  def load(names) when is_list(names) do
    names
    |> Enum.uniq()
    |> Enum.flat_map(&load_one/1)
  end

  def load(name) when is_binary(name), do: load([name])
  def load(_names), do: []

  defp load_one(name) when is_binary(name) do
    case Map.fetch(@builtin_skills, name) do
      {:ok, relative_path} ->
        path = Path.join(skills_dir(), relative_path)

        case safe_builtin_path(path) do
          {:ok, path} ->
            case File.read(path) do
              {:ok, text} ->
                [
                  %{
                    "name" => name,
                    "path" => path,
                    "content" => String.trim(text)
                  }
                ]

              {:error, _reason} ->
                []
            end

          {:error, _reason} ->
            []
        end

      :error ->
        []
    end
  end

  defp load_one(_name), do: []

  defp safe_builtin_path(path) do
    root = Path.expand(skills_dir())
    expanded = Path.expand(path)

    if expanded == root or String.starts_with?(expanded, root <> "/") do
      {:ok, expanded}
    else
      {:error, :outside_builtin_skills}
    end
  end

  defp skills_dir do
    Path.join(priv_dir(), "skills")
  end

  defp priv_dir do
    case :code.priv_dir(:avcs) do
      path when is_list(path) -> List.to_string(path)
      {:error, _reason} -> Path.expand("priv", File.cwd!())
    end
  end
end
