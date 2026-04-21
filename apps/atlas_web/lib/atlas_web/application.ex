defmodule AtlasWeb.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Atlas.PubSub is supervised by Atlas.Application — :atlas is an umbrella
    # dep of :atlas_web, so it is already up by the time this runs.
    children = [
      AtlasWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:atlas_web, :dns_cluster_query) || :ignore},
      AtlasWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: AtlasWeb.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    AtlasWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
