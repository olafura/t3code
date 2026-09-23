defmodule T3.Shell do
  @moduledoc """
  The cluster-wide sidebar: every project and thread row on every node.

  Rows are `{kind, row}` where `kind` is `"project"` or `"thread"` and `row` is the
  shape the client renders (`T3.Projection.row/3`). This node's rows come from the
  store's `shell` table and from stream servers as threads change; peers push theirs.
  They live in a protected ETS table keyed by `{node, stream_id}`, so any process can
  read the whole shell without copying it through this server. When a peer goes down
  its rows stay, marked offline, so a sleeping laptop's threads remain visible.

  Each node's environment descriptor (`T3.Environment.descriptor/0`) travels with its
  rows, so clients can list and label every machine, online or not.

  Subscribers receive `{:t3_shell, {:rows, node, [{id, {kind, row}}]}}`,
  `{:t3_shell, {:environment, node, descriptor}}` and
  `{:t3_shell, {:node, node, :up | :down}}`.
  """

  use GenServer

  require Logger

  @table __MODULE__
  @nodes T3.Shell.Nodes

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Every known row as `{{node, stream_id}, {kind, row}}`."
  @spec rows() :: [{{node, String.t()}, {String.t(), map}}]
  def rows, do: :ets.tab2list(@table)

  @doc "Every known node's environment descriptor as `{node, descriptor}`."
  @spec environments() :: [{node, map}]
  def environments, do: :ets.tab2list(@nodes)

  @doc "Nodes whose shell is currently reachable, this one included."
  @spec online_nodes() :: [node]
  def online_nodes, do: GenServer.call(__MODULE__, :online_nodes)

  @spec subscribe(pid) :: :ok
  def subscribe(pid), do: GenServer.call(__MODULE__, {:subscribe, pid})

  @doc "Replaces a local stream's row; called by stream servers after they recompute it."
  @spec put_row(String.t(), {String.t(), map}) :: :ok
  def put_row(stream_id, kind_row),
    do: GenServer.cast(__MODULE__, {:put_row, stream_id, kind_row})

  # --- server ------------------------------------------------------------------

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :protected, read_concurrency: true])
    :ets.new(@nodes, [:named_table, :protected, read_concurrency: true])
    :ok = :net_kernel.monitor_nodes(true)
    path = T3.Store.path()
    stored = T3.Store.list_shell(path)
    :ets.insert(@table, for({id, kind, row} <- stored, do: {{node(), id}, {kind, row}}))
    :ets.insert(@nodes, {node(), T3.Environment.descriptor()})
    for peer <- Node.list(), do: push_all(peer)
    backfill(path, MapSet.new(stored, &elem(&1, 0)))
    {:ok, %{subscribers: %{}, online: MapSet.new([node() | Node.list()])}}
  end

  @impl true
  def handle_call(:online_nodes, _from, state), do: {:reply, MapSet.to_list(state.online), state}

  def handle_call({:subscribe, pid}, _from, state) do
    ref = Process.monitor(pid)
    {:reply, :ok, %{state | subscribers: Map.put(state.subscribers, pid, ref)}}
  end

  @impl true
  def handle_cast({:put_row, stream_id, kind_row}, state) do
    case :ets.lookup(@table, {node(), stream_id}) do
      [{_, ^kind_row}] ->
        :ok

      _ ->
        :ets.insert(@table, {{node(), stream_id}, kind_row})
        for peer <- Node.list(), do: push_rows(peer, [{stream_id, kind_row}])
        notify(state, {:rows, node(), [{stream_id, kind_row}]})
    end

    {:noreply, state}
  end

  def handle_cast({:peer_environment, peer, descriptor}, state) do
    :ets.insert(@nodes, {peer, descriptor})
    notify(state, {:environment, peer, descriptor})
    {:noreply, state}
  end

  # Rows pushed by a peer: its full shell on connect, single rows afterwards.
  def handle_cast({:peer_rows, peer, rows}, state) do
    :ets.insert(@table, for({id, kind_row} <- rows, do: {{peer, id}, kind_row}))
    notify(state, {:rows, peer, rows})
    {:noreply, state}
  end

  @impl true
  def handle_info({:nodeup, peer}, state) do
    push_all(peer)
    notify(state, {:node, peer, :up})
    {:noreply, %{state | online: MapSet.put(state.online, peer)}}
  end

  def handle_info({:nodedown, peer}, state) do
    notify(state, {:node, peer, :down})
    {:noreply, %{state | online: MapSet.delete(state.online, peer)}}
  end

  def handle_info({:DOWN, _ref, :process, pid, _}, state),
    do: {:noreply, %{state | subscribers: Map.delete(state.subscribers, pid)}}

  def handle_info(_other, state), do: {:noreply, state}

  defp push_rows(peer, rows), do: GenServer.cast({__MODULE__, peer}, {:peer_rows, node(), rows})

  defp push_all(peer) do
    GenServer.cast({__MODULE__, peer}, {:peer_environment, node(), T3.Environment.descriptor()})

    push_rows(
      peer,
      for([id, kind_row] <- :ets.match(@table, {{node(), :"$1"}, :"$2"}), do: {id, kind_row})
    )
  end

  defp notify(state, message),
    do: for({pid, _} <- state.subscribers, do: send(pid, {:t3_shell, message}))

  # Streams without a stored row (a store from before rows were kept) get one in the
  # background; boot does not wait for it.
  defp backfill(path, have) do
    missing = for %{id: id} <- T3.Store.list_streams(path), not MapSet.member?(have, id), do: id

    if missing != [] do
      Task.start(fn ->
        Logger.info("computing #{length(missing)} missing sidebar rows")

        for id <- missing,
            {_kind, _row} = kind_row <- [T3.Projection.rebuild(id)],
            do: put_row(id, kind_row)
      end)
    end
  end
end
