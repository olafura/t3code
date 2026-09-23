defmodule T3.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      if Application.fetch_env!(:t3, :start_node) do
        home = Application.fetch_env!(:t3, :home)

        [
          {T3.Store, path: Path.join(home, "t3.sqlite")},
          T3.Auth,
          T3.Streams,
          T3.Shell,
          {Registry, keys: :unique, name: T3.Codex.Registry},
          {Registry, keys: :unique, name: T3.Claude.Registry},
          {DynamicSupervisor, name: T3.Codex.Supervisor, strategy: :one_for_one},
          Supervisor.child_spec({Task, &T3.Codex.Provider.load/0}, id: :codex_models),
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
