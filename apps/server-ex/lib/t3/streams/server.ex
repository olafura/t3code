defmodule T3.Streams.Server do
  @moduledoc """
  Owns the live state of one stream and its subscribers.

  Subscribers receive, in order:

    * `{:t3_stream, stream_id, {:snapshot, seq, updated_at, rows, :more | :done}}` chunks when they
      start fresh or have fallen too far behind, where `rows` is a list of
      `{kind, entity_id, entity}`, or `{:t3_stream, stream_id, {:events, events}}`
      replaying only what they missed,
    * `{:t3_stream, stream_id, {:live, seq}}` once they are caught up, then
    * `{:t3_stream, stream_id, {:events, events}}` for every later commit.

  Snapshots are split into chunks of about `@chunk_bytes` because a subscriber may be
  on another node, and one large message would stall every other message on that
  node connection until it finished.

  Replay reads the log, not memory, so a reconnecting client costs one query rather
  than a buffered copy of the thread. The process hibernates between bursts and stops
  after `@idle_stop` with no subscribers; it writes a snapshot on the way out when
  enough events accumulated since the last one.
  """

  use GenServer, restart: :transient

  alias T3.{Store, StreamState}

  @state_version 1
  @idle_stop :timer.minutes(5)
  @snapshot_every 500
  # A subscriber further behind than this gets a snapshot instead of a replay.
  @max_replay 2_000
  @chunk_bytes 256 * 1024
  # While a thread streams, its sidebar row is recomputed at most this often.
  @shell_debounce 250

  def start_link(stream_id),
    do:
      GenServer.start_link(__MODULE__, stream_id,
        name: {:via, Registry, {T3.Streams.Registry, stream_id}},
        hibernate_after: 15_000
      )

  @spec subscribe(String.t(), pid, non_neg_integer | nil) :: :ok
  def subscribe(stream_id, pid, offset \\ nil),
    do: stream_id |> T3.Streams.ensure() |> GenServer.call({:subscribe, pid, offset})

  @spec unsubscribe(String.t(), pid) :: :ok
  def unsubscribe(stream_id, pid) do
    case Registry.lookup(T3.Streams.Registry, stream_id) do
      [{server, _}] -> GenServer.cast(server, {:unsubscribe, pid})
      [] -> :ok
    end
  end

  @spec commit(GenServer.server(), Store.stream_kind(), [Store.change()]) ::
          {:ok, non_neg_integer}
  def commit(server, stream_kind, changes),
    do: GenServer.call(server, {:commit, stream_kind, changes})

  @doc """
  Runs `fun` against the stream's current state inside the stream process and
  commits the changes it returns, so a decision and its effects are atomic with
  respect to other commits. `fun` returns `{changes, reply}`; an empty change list
  commits nothing.
  """
  @spec transact(GenServer.server(), Store.stream_kind(), (StreamState.t() ->
                                                             {[Store.change()], reply})) ::
          reply
        when reply: term
  def transact(server, stream_kind, fun),
    do: GenServer.call(server, {:transact, stream_kind, fun}, 30_000)

  @spec state(GenServer.server()) :: StreamState.t()
  def state(server), do: GenServer.call(server, :state)

  @impl true
  def init(stream_id) do
    path = Store.path()
    state = StreamState.load(path, stream_id)

    {:ok,
     %{
       v: @state_version,
       id: stream_id,
       path: path,
       stream: state,
       snapshot_seq: state.seq,
       shell_scheduled: false,
       subscribers: %{}
     }, @idle_stop}
  end

  @impl true
  def handle_call({:subscribe, pid, offset}, _from, state) do
    deliver_initial(state, pid, offset)
    ref = Process.monitor(pid)
    {:reply, :ok, %{state | subscribers: Map.put(state.subscribers, pid, ref)}}
  end

  def handle_call({:commit, stream_kind, changes}, _from, state) do
    {:ok, last} = Store.append([{stream_kind, state.id, changes}])
    first = last - length(changes) + 1
    at = System.os_time(:millisecond)

    events =
      changes
      |> Enum.with_index(first)
      |> Enum.map(fn {change, seq} ->
        {kind, entity, patch, change_at} =
          case change do
            {kind, entity, patch} -> {kind, entity, patch, at}
            {_, _, _, _} = timed -> timed
          end

        %{seq: seq, kind: kind, entity: entity, patch: patch, at: change_at}
      end)

    stream = Enum.reduce(events, state.stream, &StreamState.apply_event(&2, &1))
    T3.Search.index(state.id, events, stream)
    broadcast(state, {:events, events})
    state = schedule_shell(%{state | stream: stream})
    {:reply, {:ok, last}, state, timeout(state)}
  end

  def handle_call({:transact, stream_kind, fun}, from, state) do
    case fun.(state.stream) do
      {[], reply} ->
        {:reply, reply, state, timeout(state)}

      {changes, reply} ->
        {:reply, {:ok, _last}, state, _} =
          handle_call({:commit, stream_kind, changes}, from, state)

        {:reply, reply, state, timeout(state)}
    end
  end

  def handle_call(:state, _from, state), do: {:reply, state.stream, state, timeout(state)}

  @impl true
  def handle_cast({:unsubscribe, pid}, state) do
    {ref, subscribers} = Map.pop(state.subscribers, pid)
    if ref, do: Process.demonitor(ref, [:flush])
    state = %{state | subscribers: subscribers}
    {:noreply, state, timeout(state)}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _}, state) do
    state = %{state | subscribers: Map.delete(state.subscribers, pid)}
    {:noreply, state, timeout(state)}
  end

  def handle_info(:shell, state) do
    with {_kind, _row} = kind_row <- T3.Projection.row(state.path, state.id, state.stream) do
      :ok = Store.put_shell(state.id, state.stream.seq, kind_row)
      T3.Shell.put_row(state.id, kind_row)
    end

    state = %{state | shell_scheduled: false}
    {:noreply, state, timeout(state)}
  end

  def handle_info(:timeout, state), do: {:stop, :normal, state}

  @impl true
  def terminate(_reason, state) do
    if state.shell_scheduled, do: handle_info(:shell, state)

    if state.stream.seq - state.snapshot_seq >= @snapshot_every,
      do: Store.put_snapshot(state.id, state.stream.seq, state.stream)
  end

  @impl true
  def code_change(_old_vsn, state, _extra),
    do: {:ok, %{state | v: @state_version, stream: StreamState.migrate(state.stream)}}

  defp deliver_initial(state, pid, offset) do
    replay =
      if is_integer(offset) and offset <= state.stream.seq,
        do:
          Store.reduce_stream(state.path, state.id, offset, [], &[&1 | &2],
            limit: @max_replay + 1
          ),
        else: :none

    case replay do
      events when is_list(events) and length(events) <= @max_replay ->
        send(pid, {:t3_stream, state.id, {:events, Enum.reverse(events)}})

      _ ->
        send_snapshot(state, pid)
    end

    send(pid, {:t3_stream, state.id, {:live, state.stream.seq}})
  end

  defp send_snapshot(state, pid) do
    # Creation order, which is the order lists such as runs and turn items are shown in.
    chunks = chunk_rows(StreamState.rows(state.stream), [], 0, [])
    last = length(chunks) - 1

    for {chunk, i} <- Enum.with_index(chunks),
        do:
          send(
            pid,
            {:t3_stream, state.id,
             {:snapshot, state.stream.seq, state.stream.updated_at, chunk,
              if(i == last, do: :done, else: :more)}}
          )
  end

  defp chunk_rows([], current, _size, acc), do: Enum.reverse([Enum.reverse(current) | acc])

  defp chunk_rows([row | rest], current, size, acc) do
    row_size = :erlang.external_size(row)

    if current != [] and size + row_size > @chunk_bytes,
      do: chunk_rows(rest, [row], row_size, [Enum.reverse(current) | acc]),
      else: chunk_rows(rest, [row | current], size + row_size, acc)
  end

  defp schedule_shell(%{shell_scheduled: true} = state), do: state

  defp schedule_shell(state) do
    Process.send_after(self(), :shell, @shell_debounce)
    %{state | shell_scheduled: true}
  end

  defp broadcast(state, message),
    do: for({pid, _} <- state.subscribers, do: send(pid, {:t3_stream, state.id, message}))

  defp timeout(%{subscribers: subs}) when map_size(subs) == 0, do: @idle_stop
  defp timeout(_state), do: :infinity
end
