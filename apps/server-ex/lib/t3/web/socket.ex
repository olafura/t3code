defmodule T3.Web.Socket do
  @moduledoc """
  One client connection. See `T3.Web.Protocol` for the wire format.

  Stream subscriptions may live on any node in the cluster; the owning node's stream
  server sends straight to this process. Incoming events are buffered and flushed
  once the mailbox is drained, merged per entity, so a burst of streaming tokens
  becomes one frame. A subscription whose unsent buffer passes `@max_buffered` is
  dropped with a `resync`; the client resubscribes from its offset and the stream
  replays from the log instead of this process holding the backlog.
  """

  @behaviour WebSock

  alias T3.Web.Protocol

  @max_buffered 8 * 1024 * 1024

  @impl true
  def init(_opts) do
    state = %{subs: %{}, by_stream: %{}, buffers: %{}, flush_scheduled: false}

    {:push,
     Protocol.encode(%{
       "t" => "hello",
       "protocol" => Protocol.version(),
       "node" => Atom.to_string(node())
     }), state}
  end

  @impl true
  def handle_in({frame, [opcode: :text]}, state) do
    case Protocol.decode(frame, [node() | Node.list()]) do
      {:ok, :ping} -> {:push, Protocol.encode(%{"t" => "pong"}), state}
      {:ok, {:sub, id, shape, offset}} -> subscribe(state, id, shape, offset)
      {:ok, {:unsub, id}} -> {:ok, unsubscribe(state, id)}
      {:error, reason} -> {:push, Protocol.encode(%{"t" => "error", "reason" => reason}), state}
    end
  end

  def handle_in(_binary, state), do: {:ok, state}

  @impl true
  def handle_info({:t3_stream, stream_id, message}, state) do
    case state.by_stream do
      %{^stream_id => id} -> stream_message(state, id, message)
      _ -> {:ok, state}
    end
  end

  def handle_info({:t3_shell, message}, state) do
    case Enum.find(state.subs, &match?({_, :shell}, &1)) do
      {id, :shell} -> {:push, Protocol.encode(shell_message(id, message)), state}
      nil -> {:ok, state}
    end
  end

  def handle_info(:flush, state) do
    {frames, state} = flush(state)
    {:push, frames, %{state | flush_scheduled: false}}
  end

  def handle_info(_other, state), do: {:ok, state}

  @impl true
  def terminate(_reason, state) do
    for {id, _} <- state.subs, do: unsubscribe(state, id)
    :ok
  end

  # --- subscriptions -------------------------------------------------------------

  defp subscribe(state, id, :shell, _offset) do
    :ok = T3.Shell.subscribe(self())
    online = MapSet.new(T3.Shell.online_nodes())

    rows =
      for {{node, stream}, {kind, row}} <- T3.Shell.rows(),
          do: [Atom.to_string(node), stream, kind, row]

    nodes =
      for {node, descriptor} <- T3.Shell.environments() do
        %{"node" => Atom.to_string(node), "online" => node in online, "environment" => descriptor}
      end

    frame = %{"t" => "shell", "id" => id, "nodes" => nodes, "rows" => rows}

    {:push, Protocol.encode(frame), put_in(state.subs[id], :shell)}
  end

  # A node's ServerConfig, fetched once; it is small and changes with settings.
  defp subscribe(state, id, {:config, node}, _offset) do
    frame =
      try do
        %{
          "t" => "config",
          "id" => id,
          "config" => :erpc.call(node, T3.Environment, :server_config, [], 15_000)
        }
      catch
        :error, {:erpc, reason} ->
          %{"t" => "error", "id" => id, "reason" => "node unavailable: #{reason}"}
      end

    {:push, Protocol.encode(frame), state}
  end

  defp subscribe(state, id, {:stream, node, stream_id} = shape, offset) do
    if Map.has_key?(state.by_stream, stream_id) do
      {:push, Protocol.encode(%{"t" => "error", "id" => id, "reason" => "already subscribed"}),
       state}
    else
      try do
        :ok = :erpc.call(node, T3.Streams, :subscribe, [stream_id, self(), offset], 15_000)

        {:ok,
         %{
           state
           | subs: Map.put(state.subs, id, shape),
             by_stream: Map.put(state.by_stream, stream_id, id)
         }}
      catch
        # The owning node went away or timed out; the client retries when it is back.
        :error, {:erpc, reason} ->
          {:push,
           Protocol.encode(%{
             "t" => "error",
             "id" => id,
             "reason" => "node unavailable: #{reason}"
           }), state}
      end
    end
  end

  defp unsubscribe(state, id) do
    case Map.pop(state.subs, id) do
      {{:stream, node, stream_id}, subs} ->
        :erpc.cast(node, T3.Streams, :unsubscribe, [stream_id, self()])

        %{
          state
          | subs: subs,
            by_stream: Map.delete(state.by_stream, stream_id),
            buffers: Map.delete(state.buffers, id)
        }

      {_, subs} ->
        %{state | subs: subs}
    end
  end

  defp stream_message(state, id, {:snapshot, seq, updated_at, rows, part_state}) do
    part = get_in(state.buffers, [id, :snapshot_part]) || 0

    frame = %{
      "t" => "snapshot",
      "id" => id,
      "offset" => seq,
      "at" => updated_at,
      "part" => part,
      "done" => part_state == :done,
      "rows" => for({kind, eid, entity} <- rows, do: [kind, eid, entity])
    }

    buffers =
      if part_state == :done,
        do: Map.delete(state.buffers, id),
        else: Map.put(state.buffers, id, %{events: [], bytes: 0, snapshot_part: part + 1})

    {:push, Protocol.encode(frame), %{state | buffers: buffers}}
  end

  # Replayed events may still be buffered; they go out before the live marker.
  defp stream_message(state, id, {:live, seq}) do
    {frames, state} = flush(state)
    {:push, frames ++ [Protocol.encode(%{"t" => "live", "id" => id, "offset" => seq})], state}
  end

  defp stream_message(state, _id, {:events, []}), do: {:ok, state}

  defp stream_message(state, id, {:events, events}) do
    buffer = Map.get(state.buffers, id, %{events: [], bytes: 0})
    bytes = buffer.bytes + Enum.reduce(events, 0, &(:erlang.external_size(&1.patch) + &2))

    if bytes > @max_buffered do
      # The client has everything before the oldest event it has not been sent.
      oldest = List.last(buffer.events) || hd(events)
      state = unsubscribe(state, id)
      {:push, Protocol.encode(%{"t" => "resync", "id" => id, "offset" => oldest.seq - 1}), state}
    else
      buffer = %{buffer | events: Enum.reverse(events, buffer.events), bytes: bytes}
      state = %{state | buffers: Map.put(state.buffers, id, buffer)}
      {:ok, schedule_flush(state)}
    end
  end

  defp flush(state) do
    frames =
      for {id, %{events: events}} <- state.buffers, events != [] do
        events = events |> Enum.reverse() |> Protocol.coalesce()

        Protocol.encode(%{
          "t" => "events",
          "id" => id,
          "offset" => List.last(events).seq,
          "events" => for(e <- events, do: [e.seq, e.kind, e.entity, e.patch, e.at])
        })
      end

    buffers =
      Map.new(state.buffers, fn {id, buffer} -> {id, %{buffer | events: [], bytes: 0}} end)

    {frames, %{state | buffers: buffers}}
  end

  # The flush message lands behind everything already in the mailbox, so each
  # flush drains a whole burst.
  defp schedule_flush(%{flush_scheduled: true} = state), do: state

  defp schedule_flush(state) do
    send(self(), :flush)
    %{state | flush_scheduled: true}
  end

  defp shell_message(id, {:rows, node, rows}),
    do: %{
      "t" => "shell.rows",
      "id" => id,
      "node" => Atom.to_string(node),
      "rows" => for({sid, {kind, row}} <- rows, do: [sid, kind, row])
    }

  defp shell_message(id, {:environment, node, descriptor}),
    do: %{
      "t" => "shell.environment",
      "id" => id,
      "node" => Atom.to_string(node),
      "environment" => descriptor
    }

  defp shell_message(id, {:node, node, status}),
    do: %{
      "t" => "shell.node",
      "id" => id,
      "node" => Atom.to_string(node),
      "online" => status == :up
    }
end
