defmodule Avcs.Agent.Harness.Codex do
  @moduledoc false

  @behaviour Avcs.Agent.Harness

  @default_client Avcs.Agent.CodexAppServerPool

  @impl true
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
    codex_client = codex_client()

    cond do
      module_exports?(codex_client, :run_turn, 8) ->
        codex_client.run_turn(
          project,
          avcs_thread_id,
          avcs_turn_id,
          remote_thread_id,
          text,
          reference_paths,
          on_event,
          opts
        )
        |> normalize_run_result()

      module_exports?(codex_client, :run_turn, 6) ->
        codex_client.run_turn(project, remote_thread_id, text, reference_paths, on_event, opts)
        |> normalize_run_result()

      module_exports?(codex_client, :run_turn, 5) ->
        codex_client.run_turn(project, remote_thread_id, text, reference_paths, on_event)
        |> normalize_run_result()

      true ->
        {:error, :run_turn_unsupported}
    end
  end

  @impl true
  def active_turn(project, avcs_thread_id) do
    codex_client = codex_client()

    if module_exports?(codex_client, :active_turn, 2) do
      codex_client.active_turn(project, avcs_thread_id)
    else
      :none
    end
  end

  @impl true
  def steer_turn(project, avcs_thread_id, text, reference_paths, opts) do
    codex_client = codex_client()

    if module_exports?(codex_client, :steer_turn, 5) do
      codex_client.steer_turn(project, avcs_thread_id, text, reference_paths, opts)
    else
      {:error, :steer_unsupported}
    end
  end

  @impl true
  def interrupt_turn(project, avcs_thread_id, avcs_turn_id) do
    codex_client = codex_client()

    if module_exports?(codex_client, :interrupt_turn, 3) do
      codex_client.interrupt_turn(project, avcs_thread_id, avcs_turn_id)
    else
      {:error, :interrupt_unsupported}
    end
  end

  @impl true
  def prepare_rerun(
        _project,
        _avcs_thread_id,
        _avcs_turn_id,
        _remote_thread_id,
        rollback_turn_count,
        _opts
      )
      when not is_integer(rollback_turn_count) or rollback_turn_count <= 0 do
    :ok
  end

  def prepare_rerun(
        _project,
        _avcs_thread_id,
        _avcs_turn_id,
        remote_thread_id,
        rollback_turn_count,
        opts
      )
      when is_binary(remote_thread_id) and remote_thread_id != "" do
    codex_client = codex_client()

    with true <- module_exports?(codex_client, :fork_thread, 2),
         true <- module_exports?(codex_client, :rollback_thread, 3),
         {:ok, forked_thread} <- codex_client.fork_thread(remote_thread_id, opts),
         forked_thread_id when is_binary(forked_thread_id) and forked_thread_id != "" <-
           forked_thread["id"],
         {:ok, rolled_back_thread} <-
           codex_client.rollback_thread(forked_thread_id, rollback_turn_count, opts),
         rolled_back_thread_id
         when is_binary(rolled_back_thread_id) and rolled_back_thread_id != "" <-
           rolled_back_thread["id"] || forked_thread_id do
      {:ok, %{remote_thread_id: rolled_back_thread_id}}
    else
      false -> {:error, :rerun_unsupported}
      {:error, reason} -> {:error, reason}
      reason -> {:error, reason}
    end
  end

  def prepare_rerun(_project, _avcs_thread_id, _avcs_turn_id, _remote_thread_id, _count, _opts) do
    :ok
  end

  @impl true
  def read_thread(remote_thread_id, opts) do
    codex_client = codex_client()

    if module_exports?(codex_client, :read_thread, 2) do
      codex_client.read_thread(remote_thread_id, opts)
    else
      {:error, :thread_read_unsupported}
    end
  end

  @impl true
  def respond_approval(avcs_thread_id, avcs_turn_id, payload) do
    codex_client = codex_client()

    if module_exports?(codex_client, :respond_approval, 3) do
      codex_client.respond_approval(avcs_thread_id, avcs_turn_id, payload)
    else
      {:error, :approval_response_unsupported}
    end
  end

  @impl true
  def list_models(opts) do
    codex_client = codex_client()

    cond do
      module_exports?(codex_client, :list_models, 1) ->
        codex_client.list_models(opts)

      module_exports?(codex_client, :list_models, 0) ->
        codex_client.list_models()

      true ->
        {:error, :models_list_unsupported}
    end
  end

  def pool_managed? do
    codex_client = codex_client()

    module_exports?(codex_client, :active_turn, 2) and
      module_exports?(codex_client, :steer_turn, 5) and
      module_exports?(codex_client, :run_turn, 8)
  end

  def available? do
    codex_client = codex_client()

    cond do
      module_exports?(codex_client, :available?, 0) ->
        codex_client.available?()

      module_exports?(Avcs.Agent.CodexClient, :available?, 0) ->
        Avcs.Agent.CodexClient.available?()

      true ->
        true
    end
  end

  defp codex_client do
    Application.get_env(:avcs, :codex_client, @default_client)
  end

  defp normalize_run_result({:ok, result}) when is_map(result) do
    {:ok,
     %{
       agent_harness: "codex",
       remote_thread_id:
         value(result, :remote_thread_id, "remote_thread_id") ||
           value(result, :codex_thread_id, "codex_thread_id"),
       remote_turn_id:
         value(result, :remote_turn_id, "remote_turn_id") ||
           value(result, :codex_turn_id, "codex_turn_id"),
       remote_model:
         value(result, :remote_model, "remote_model") || value(result, :model, "model"),
       assistant_text: value(result, :assistant_text, "assistant_text") || "",
       items: value(result, :items, "items") || [],
       output_paths: value(result, :output_paths, "output_paths") || [],
       thread_name: value(result, :thread_name, "thread_name")
     }}
  end

  defp normalize_run_result(result), do: result

  defp value(map, atom_key, string_key) do
    Map.get(map, atom_key) || Map.get(map, string_key)
  end

  defp module_exports?(module, function, arity) when is_atom(module) do
    Code.ensure_loaded?(module) and function_exported?(module, function, arity)
  end

  defp module_exports?(_module, _function, _arity), do: false
end
