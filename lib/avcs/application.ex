defmodule Avcs.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      AvcsWeb.Telemetry,
      Avcs.Repo,
      {Ecto.Migrator,
       repos: Application.fetch_env!(:avcs, :ecto_repos), skip: skip_migrations?()},
      {DNSCluster, query: Application.get_env(:avcs, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Avcs.PubSub},
      Avcs.Session,
      {Registry, keys: :unique, name: Avcs.Agent.RunnerRegistry},
      {DynamicSupervisor, strategy: :one_for_one, name: Avcs.Agent.CodexClientSupervisor},
      Avcs.Agent.CodexAppServerPool,
      {Task.Supervisor, name: Avcs.Agent.TaskSupervisor},
      # Start to serve requests, typically the last entry
      AvcsWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Avcs.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    AvcsWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp skip_migrations?() do
    # Desktop releases keep user/project data in local-first stores and do not
    # need Ecto's release migrator for the runtime Repo placeholder.
    System.get_env("AVCS_DESKTOP") == "true" || System.get_env("RELEASE_NAME") == nil
  end
end
