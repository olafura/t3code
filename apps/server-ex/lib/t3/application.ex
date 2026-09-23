defmodule T3.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      if Application.fetch_env!(:t3, :start_node) do
        :ok = T3.Desktop.configure()
        home = Application.fetch_env!(:t3, :home)

        [
          {T3.Store, path: Path.join(home, "t3.sqlite")},
          T3.Auth,
          T3.Settings,
          T3.Streams,
          T3.Shell,
          # Turns this node was running when it stopped end as interrupted.
          Supervisor.child_spec({Task, &T3.Orchestration.Recovery.run/0}, id: :recovery),
          {Registry, keys: :unique, name: T3.Codex.Registry},
          {Registry, keys: :unique, name: T3.Claude.Registry},
          {DynamicSupervisor, name: T3.Codex.Supervisor, strategy: :one_for_one},
          {Registry, keys: :unique, name: T3.Terminal.Registry},
          {DynamicSupervisor, name: T3.Terminal.Supervisor, strategy: :one_for_one},
          T3.Terminal.Hub,
          {Registry, keys: :unique, name: T3.Vcs.Registry},
          {Registry, keys: :unique, name: T3.ProviderAuth.Registry},
          {DynamicSupervisor, name: T3.ProviderAuth.Supervisor, strategy: :one_for_one},
          {DynamicSupervisor, name: T3.Vcs.Supervisor, strategy: :one_for_one},
          Supervisor.child_spec({Task, &T3.Codex.Provider.load/0}, id: :codex_models),
          {Registry, keys: :unique, name: T3.Acp.Registry},
          Supervisor.child_spec({Task, &T3.Acp.load/0}, id: :acp_models),
          T3.Web
        ] ++ discovery(home)
      else
        []
      end

    Supervisor.start_link(children, strategy: :one_for_one, name: T3.Supervisor)
  end

  # Named nodes find peers listed in T3_PEERS (node names such as t3@192.168.1.20);
  # nodes with cluster certificates also search the tailnet.
  defp discovery(home) do
    static =
      case System.get_env("T3_PEERS") do
        nil -> []
        peers -> [static: [strategy: Cluster.Strategy.Epmd, config: [hosts: parse_peers(peers)]]]
      end

    tailnet =
      if T3.Cluster.address(home), do: [tailnet: [strategy: T3.Cluster.Tailscale]], else: []

    if Node.alive?() and static ++ tailnet != [],
      do: [{Cluster.Supervisor, [static ++ tailnet, [name: T3.ClusterSupervisor]]}],
      else: []
  end

  defp parse_peers(peers),
    do: for(p <- String.split(peers, ",", trim: true), do: p |> String.trim() |> String.to_atom())
end
