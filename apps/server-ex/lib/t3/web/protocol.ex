defmodule T3.Web.Protocol do
  @moduledoc """
  The client wire protocol (version 3): JSON text frames over one WebSocket.

  A client subscribes to *shapes* and keeps each one in sync from an offset, the way
  Electric shapes work:

    * `{"type": "shell"}`: every node's environment and every project and thread
      summary on it
    * `{"type": "stream", "node": n, "stream": id}`: one project or thread
    * `{"type": "config", "node": n}`: that node's `ServerConfig`, sent once

  Client to server:

      {"t": "sub", "id": 1, "shape": {...}, "offset": 1234 | null}
      {"t": "unsub", "id": 1}
      {"t": "ping"}

  Server to client:

      {"t": "hello", "protocol": 3, "node": n}
      {"t": "shell", "id", "nodes": [{"node", "online", "environment"}], "rows": [[node, id, kind, row]]}
      {"t": "shell.environment", "id", "node", "environment"}
      {"t": "shell.rows", "id", "node", "rows": [[id, kind, row]]}
      {"t": "shell.node", "id", "node", "online"}
      {"t": "snapshot", "id", "offset", "at", "part", "rows": [[kind, id, entity]], "done"}
      {"t": "events", "id", "offset", "events": [[seq, kind, id, patch, at]]}
      {"t": "live", "id", "offset"}     (caught up; later events are live)
      {"t": "resync", "id", "offset"}   (fell behind: resubscribe from offset)
      {"t": "error", "id", "reason"}
      {"t": "config", "id", "config"}
      {"t": "pong"}

  Shell rows are `OrchestrationV2ThreadShell` (`kind` "thread") or
  `OrchestrationProjectShell` (`kind` "project") in their JSON encoding.

  A `snapshot` with `"part": 0` replaces the client's copy of the shape; later parts
  add to it, and rows arrive in creation order. `events` carry `T3.Patch` values,
  already merged per entity, with `at` in unix ms.
  """

  @version 3

  def version, do: @version

  @type request ::
          {:sub, integer, :shell | {:stream, node, String.t()} | {:config, node},
           non_neg_integer | nil}
          | {:unsub, integer}
          | :ping

  @spec decode(binary, [node]) :: {:ok, request} | {:error, String.t()}
  def decode(frame, known_nodes) do
    case JSON.decode!(frame) do
      %{"t" => "sub", "id" => id, "shape" => shape} = msg when is_integer(id) ->
        with {:ok, shape} <- decode_shape(shape, known_nodes),
             do: {:ok, {:sub, id, shape, offset(msg["offset"])}}

      %{"t" => "unsub", "id" => id} when is_integer(id) ->
        {:ok, {:unsub, id}}

      %{"t" => "ping"} ->
        {:ok, :ping}

      _ ->
        {:error, "unknown message"}
    end
  rescue
    _ -> {:error, "invalid json"}
  end

  defp decode_shape(%{"type" => "shell"}, _nodes), do: {:ok, :shell}

  defp decode_shape(%{"type" => "stream", "node" => node, "stream" => id}, nodes)
       when is_binary(id) do
    # Only nodes this server knows about; never create atoms from client input.
    case Enum.find(nodes, &(Atom.to_string(&1) == node)) do
      nil -> {:error, "unknown node"}
      node -> {:ok, {:stream, node, id}}
    end
  end

  defp decode_shape(%{"type" => "config", "node" => node}, nodes) do
    case Enum.find(nodes, &(Atom.to_string(&1) == node)) do
      nil -> {:error, "unknown node"}
      node -> {:ok, {:config, node}}
    end
  end

  defp decode_shape(_, _), do: {:error, "unknown shape"}

  defp offset(n) when is_integer(n) and n >= 0, do: n
  defp offset(_), do: nil

  @spec encode(map) :: {:text, iodata}
  def encode(message), do: {:text, JSON.encode_to_iodata!(message)}

  @doc """
  Merges consecutive patches to the same entity. The result is ordered by each
  entity's latest seq, which is all the ordering the fold depends on.
  """
  @spec coalesce([T3.Store.event()]) :: [T3.Store.event()]
  def coalesce(events) do
    events
    |> Enum.reduce(%{}, fn %{kind: k, entity: id} = event, acc ->
      Map.update(acc, {k, id}, event, fn prev ->
        %{event | patch: T3.Patch.compose(prev.patch, event.patch)}
      end)
    end)
    |> Map.values()
    |> Enum.sort_by(& &1.seq)
  end
end
