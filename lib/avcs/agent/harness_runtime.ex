defmodule Avcs.Agent.HarnessRuntime do
  @moduledoc false

  @default_harness Avcs.Agent.Harness.Codex
  @avcs_agent_harness Avcs.Agent.Harness.AvcsAgent

  def run_turn(
        project,
        avcs_thread_id,
        avcs_turn_id,
        remote_thread_id,
        text,
        reference_paths,
        on_event,
        opts
      ) do
    call(
      :run_turn,
      [
        project,
        avcs_thread_id,
        avcs_turn_id,
        remote_thread_id,
        text,
        reference_paths,
        on_event,
        opts
      ],
      {:error, :run_turn_unsupported}
    )
  end

  def active_turn(project, avcs_thread_id) do
    call(:active_turn, [project, avcs_thread_id], :none)
  end

  def steer_turn(project, avcs_thread_id, text, reference_paths, opts) do
    call(
      :steer_turn,
      [project, avcs_thread_id, text, reference_paths, opts],
      {:error, :steer_unsupported}
    )
  end

  def interrupt_turn(project, avcs_thread_id, avcs_turn_id) do
    call(
      :interrupt_turn,
      [project, avcs_thread_id, avcs_turn_id],
      {:error, :interrupt_unsupported}
    )
  end

  def prepare_rerun(
        project,
        avcs_thread_id,
        avcs_turn_id,
        remote_thread_id,
        rollback_turn_count,
        opts
      ) do
    call(
      :prepare_rerun,
      [project, avcs_thread_id, avcs_turn_id, remote_thread_id, rollback_turn_count, opts],
      {:error, :rerun_unsupported}
    )
  end

  def read_thread(remote_thread_id, opts) do
    call(:read_thread, [remote_thread_id, opts], {:error, :thread_read_unsupported})
  end

  def respond_approval(avcs_thread_id, avcs_turn_id, payload) do
    call(
      :respond_approval,
      [avcs_thread_id, avcs_turn_id, payload],
      {:error, :approval_response_unsupported}
    )
  end

  def list_models(opts \\ []) do
    call(:list_models, [opts], {:error, :models_list_unsupported})
  end

  def initial_turn_status do
    if pool_managed?(), do: "queued", else: "in_progress"
  end

  def pool_managed? do
    harness = harness()

    module_exports?(harness, :pool_managed?, 0) and harness.pool_managed?()
  end

  def harness do
    case Application.get_env(:avcs, :agent_harness) do
      module when is_atom(module) and not is_nil(module) ->
        module

      setting when is_binary(setting) ->
        harness_for_setting(setting)

      _value ->
        harness_for_setting(site_harness_setting())
    end
  end

  def harness_name do
    case harness() do
      @default_harness -> "codex"
      @avcs_agent_harness -> "avcs_agent"
      module when is_atom(module) -> module |> Module.split() |> List.last() |> Macro.underscore()
      _module -> "unknown"
    end
  end

  defp call(function, args, unsupported) do
    harness = harness()
    arity = length(args)

    if module_exports?(harness, function, arity) do
      apply(harness, function, args)
    else
      unsupported
    end
  end

  defp module_exports?(module, function, arity) when is_atom(module) do
    Code.ensure_loaded?(module) and function_exported?(module, function, arity)
  end

  defp module_exports?(_module, _function, _arity), do: false

  defp site_harness_setting do
    case Avcs.SiteSettings.get_setting("agent.harness") do
      {:ok, value} when is_binary(value) -> value
      _result -> "codex"
    end
  end

  defp harness_for_setting("codex"), do: @default_harness
  defp harness_for_setting("avcs_agent"), do: @avcs_agent_harness

  defp harness_for_setting("auto") do
    cond do
      harness_available?(@default_harness) -> @default_harness
      harness_configured?(@avcs_agent_harness) -> @avcs_agent_harness
      true -> @default_harness
    end
  end

  defp harness_for_setting(_setting), do: @default_harness

  defp harness_available?(module) do
    module_exports?(module, :available?, 0) and module.available?()
  end

  defp harness_configured?(module) do
    module_exports?(module, :configured?, 0) and module.configured?()
  end
end
