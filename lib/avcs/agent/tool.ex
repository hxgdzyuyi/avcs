defmodule Avcs.Agent.Tool do
  @moduledoc false

  @type context :: map()
  @type arguments :: map()
  @type progress :: map()

  @callback name() :: String.t()
  @callback description() :: String.t()
  @callback parameters_schema() :: map()
  @callback normalize_arguments(term(), context()) :: {:ok, arguments()} | {:error, term()}
  @callback authorize(arguments(), context()) :: :ok | {:error, term()}
  @callback execute(arguments(), context()) :: {:ok, map()} | {:error, term()}

  def schema(tool_module) do
    %{
      "type" => "function",
      "function" => %{
        "name" => tool_module.name(),
        "description" => tool_module.description(),
        "parameters" => tool_module.parameters_schema()
      }
    }
  end
end
