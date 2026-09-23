defmodule T3.Cluster.Tailscale do
  @moduledoc """
  libcluster strategy that finds peers on the local tailnet.

  It reads `tailscale status --json` from the local daemon (no API key) every
  `:polling_interval` ms and tries `t3@<tailscale IPv4>` on each online peer. Peers
  without a T3 node simply refuse the connection, and peers from another cluster
  fail the TLS handshake, so trying every peer is safe.

      config :libcluster,
        topologies: [tailnet: [strategy: T3.Cluster.Tailscale, config: [polling_interval: 10_000]]]
  """

  use GenServer
  use Cluster.Strategy

  alias Cluster.Strategy.State

  @default_interval 10_000

  @impl Cluster.Strategy
  def start_link([%State{} = state]), do: GenServer.start_link(__MODULE__, state)

  @impl GenServer
  def init(state) do
    send(self(), :poll)
    {:ok, state}
  end

  @impl GenServer
  def handle_info(:poll, state) do
    nodes = discover(Keyword.get(state.config, :command, ["tailscale", "status", "--json"]))
    Cluster.Strategy.connect_nodes(state.topology, state.connect, state.list_nodes, nodes)

    Process.send_after(
      self(),
      :poll,
      Keyword.get(state.config, :polling_interval, @default_interval)
    )

    {:noreply, state}
  end

  @doc "Node names for the online peers in a `tailscale status --json` document."
  @spec peers(map) :: [node]
  def peers(%{"Peer" => peers}) when is_map(peers) do
    for {_key, %{"Online" => true, "TailscaleIPs" => ips}} <- peers,
        ip = Enum.find(ips, &String.contains?(&1, ".")),
        ip != nil,
        do: :"t3@#{ip}"
  end

  def peers(_status), do: []

  defp discover([cmd | args]) do
    case System.cmd(cmd, args, stderr_to_stdout: true) do
      {json, 0} -> json |> JSON.decode!() |> peers()
      _ -> []
    end
  rescue
    _ -> []
  end
end
