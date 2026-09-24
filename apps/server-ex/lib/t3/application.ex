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
          # The desktop app's telemetry channel, when it runs this node.
          desktop_channel(),
          T3.Streams,
          T3.Shell,
          # Turns this node was running when it stopped end as interrupted.
          %{id: :recovery, start: {T3.Orchestration.Recovery, :start_link, []}},
          Supervisor.child_spec({Task, &T3.Search.backfill/0}, id: :search_backfill),
          {Registry, keys: :unique, name: T3.Codex.Registry},
          {Registry, keys: :unique, name: T3.Claude.Registry},
          {DynamicSupervisor, name: T3.Codex.Supervisor, strategy: :one_for_one},
          {Registry, keys: :unique, name: T3.Terminal.Registry},
          {DynamicSupervisor, name: T3.Terminal.Supervisor, strategy: :one_for_one},
          T3.Terminal.Hub,
          {Registry, keys: :unique, name: T3.Vcs.Registry},
          T3.Workspace,
          T3.WorktreeSetup,
          T3.ScheduledTasks,
          T3.ProjectClones,
          T3.Preview,
          T3.PreviewAutomation,
          T3.LocalServers,
          T3.Devices,
          T3.Diagnostics,
          T3.PullRequests.Refreshes,
          T3.PullRequests.Discovery,
          T3.PullRequests.Sync,
          T3.Orchestration.Settlement,
          T3.Usage,
          T3.Mcp,
          T3.Upgrade,
          T3.BackgroundPolicy,
          T3.EnvironmentThemes,
          T3.ProviderUsageLimits,
          T3.UsageLimitSources,
          T3.StorageCleanup,
          T3.Orchestration.IdleSessions,
          {Registry, keys: :unique, name: T3.ProviderAuth.Registry},
          {DynamicSupervisor, name: T3.ProviderAuth.Supervisor, strategy: :one_for_one},
          {DynamicSupervisor, name: T3.Vcs.Supervisor, strategy: :one_for_one},
          Supervisor.child_spec({Task, &T3.Codex.Provider.load/0}, id: :codex_models),
          {Registry, keys: :unique, name: T3.Acp.Registry},
          T3.Acp.UrlAuth,
          Supervisor.child_spec({Task, &T3.Acp.load/0}, id: :acp_models),
          T3.Web,
          # A T3 Connect link's managed tunnel (`T3.Cloud`).
          T3.Cloud.Tunnel,
          T3.Cloud.Activity,
          # Turns the restart cut off go on, where the user asked for that.
          Supervisor.child_spec({Task, &T3.Orchestration.Recovery.continue/0}, id: :continue),
          # Projects that ask for it are brought up to date.
          Supervisor.child_spec({Task, &T3.Projects.auto_pull/0}, id: :auto_pull),
          Supervisor.child_spec({Task, &T3.Projects.identify_all/0}, id: :identify_projects)
        ] ++ discovery(home)
      else
        []
      end

    Supervisor.start_link(Enum.reject(children, &is_nil/1),
      strategy: :one_for_one,
      name: T3.Supervisor
    )
  end

  defp desktop_channel do
    case Application.get_env(:t3, :desktop_channel) do
      {telemetry, control} -> {T3.Desktop.Channel, transport: {:fd, telemetry, control}}
      nil -> nil
    end
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
