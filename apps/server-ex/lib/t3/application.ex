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
          T3.Web
        ] ++ discovery(home)
      else
        []
      end

    Supervisor.start_link(children, strategy: :one_for_one, name: T3.Supervisor)
  end

  # Clustered nodes find peers on the tailnet, plus any listed in T3_PEERS
  # (comma-separated node names such as t3@192.168.1.20).
  defp discovery(home) do
    if Node.alive?() and T3.Cluster.address(home) do
      static =
        case System.get_env("T3_PEERS") do
          nil ->
            []

          peers ->
            [static: [strategy: Cluster.Strategy.Epmd, config: [hosts: parse_peers(peers)]]]
        end

      [
        {Cluster.Supervisor,
         [[tailnet: [strategy: T3.Cluster.Tailscale]] ++ static, [name: T3.ClusterSupervisor]]}
      ]
    else
      []
    end
  end

  defp parse_peers(peers),
    do: for(p <- String.split(peers, ",", trim: true), do: p |> String.trim() |> String.to_atom())
end
