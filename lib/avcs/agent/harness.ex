defmodule Avcs.Agent.Harness do
  @moduledoc """
  Runtime boundary between Avcs local persistence and the agent provider.

  The contract is provider-neutral at the persistence boundary. Individual
  harnesses may still speak provider-specific wire protocols internally.
  """

  @type project :: map()
  @type avcs_thread_id :: String.t()
  @type avcs_turn_id :: String.t()
  @type remote_thread_id :: String.t() | nil
  @type event :: tuple() | map()
  @type on_event :: (event() -> term())
  @type opts :: keyword() | map()
  @type run_result :: %{
          required(:remote_thread_id) => String.t(),
          required(:remote_turn_id) => String.t() | nil,
          optional(:agent_harness) => String.t(),
          optional(:remote_model) => String.t() | nil,
          required(:assistant_text) => String.t(),
          required(:items) => [map()],
          optional(:output_paths) => [String.t()],
          optional(:thread_name) => String.t() | nil
        }

  @callback run_turn(
              project(),
              avcs_thread_id(),
              avcs_turn_id(),
              remote_thread_id(),
              String.t(),
              [String.t()],
              on_event(),
              opts()
            ) ::
              {:ok, run_result()} | {:error, :interrupted | term()}

  @callback active_turn(project(), avcs_thread_id()) ::
              {:ok, map()} | :none | {:error, term()}

  @callback steer_turn(project(), avcs_thread_id(), String.t(), [String.t()], opts()) ::
              {:ok, map()} | {:error, term()}

  @callback interrupt_turn(project(), avcs_thread_id(), avcs_turn_id()) ::
              {:ok, map()} | {:error, term()}

  @callback prepare_rerun(
              project(),
              avcs_thread_id(),
              avcs_turn_id(),
              remote_thread_id(),
              non_neg_integer(),
              opts()
            ) ::
              :ok | {:ok, %{remote_thread_id: String.t()}} | {:error, term()}

  @callback read_thread(remote_thread_id(), opts()) :: {:ok, map()} | {:error, term()}
  @callback respond_approval(avcs_thread_id(), avcs_turn_id(), map()) :: :ok | {:error, term()}
  @callback list_models(opts()) :: {:ok, [map()]} | {:error, term()}

  @optional_callbacks list_models: 1
end
