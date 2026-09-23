defmodule T3.Orchestration.TurnWriter do
  @moduledoc """
  Writes a provider turn into its thread's log; shared by the provider runtimes.

  A runtime keeps a state map with `:thread_id`, `:turn` (holding the run's
  `ids`), `:items` (native item id to its turn item, node, and message),
  `:buffer`, and `:flush_timer`. Streamed text and output are buffered for
  `@flush_ms` and written as appends; the runtime forwards its `:flush` message to
  `flush/1`.
  """

  alias T3.Orchestration
  alias T3.Orchestration.Entities
  alias T3.StreamState

  @flush_ms 50

  @doc "The turn item id for a provider's native item."
  def item_id(ids, native), do: "turn-item:#{Entities.driver(ids)}:#{native}"

  @doc """
  Creates the turn item (and its node) for a native item the first time it is seen.
  `kind` is `:assistant`, `:reasoning`, `:command`, `:file`, `:web`, or `:tool`;
  `fields` are the item type's own fields.
  """
  def ensure_item(state, native, kind, fields \\ %{}) do
    if Map.has_key?(state.items, native) do
      state
    else
      ids = state.turn.ids
      driver = Entities.driver(ids)
      at = Entities.now()
      node_id = Entities.new_id("node")
      item_id = item_id(ids, native)
      message_id = if kind == :assistant, do: "message:#{driver}:#{native}"
      item_ids = Map.put(ids, :node, node_id)
      {node_kind, type, item_fields} = shape(kind, message_id, fields)

      commit(state, fn stream ->
        [
          Orchestration.create(
            "node",
            node_id,
            Entities.node(ids, node_id, node_kind, "running", at, %{
              "nativeItemRef" => Entities.provider_ref(native, driver)
            })
          ),
          Orchestration.create(
            "turn-item",
            item_id,
            Entities.turn_item(
              item_ids,
              item_id,
              type,
              Orchestration.next_ordinal(stream),
              "running",
              at,
              item_fields
            )
            |> Map.put("nativeItemRef", Entities.provider_ref(native, driver))
          ),
          message_id &&
            Orchestration.create(
              "message",
              message_id,
              Entities.message(item_ids, message_id, "assistant", "", true, at, %{
                "nodeId" => node_id
              })
            )
        ]
      end)

      item = %{id: item_id, node: node_id, message: message_id, kind: kind}
      %{state | items: Map.put(state.items, native, item)}
    end
  end

  defp shape(:assistant, message_id, _),
    do:
      {"assistant_message", "assistant_message",
       %{"messageId" => message_id, "text" => "", "streaming" => true}}

  defp shape(:reasoning, _, _),
    do: {"reasoning", "reasoning", %{"text" => "", "streaming" => true}}

  defp shape(:command, _, fields), do: {"tool_call", "command_execution", fields}
  defp shape(:file, _, fields), do: {"tool_call", "file_change", fields}
  defp shape(:web, _, fields), do: {"tool_call", "web_search", fields}
  defp shape(:tool, _, fields), do: {"tool_call", "dynamic_tool", fields}

  @doc "Finishes an item with `status`, applying `fun` to its turn item (and message)."
  def finish_item(state, native, status, fun) do
    %{id: item_id, node: node_id, message: message_id} = Map.fetch!(state.items, native)
    at = Entities.now()

    commit(state, fn stream ->
      [
        Orchestration.upsert(
          stream,
          "turn-item",
          item_id,
          &(fun.(&1) |> Map.merge(%{"status" => status, "completedAt" => at, "updatedAt" => at}))
        ),
        Orchestration.upsert(
          stream,
          "node",
          node_id,
          &Map.merge(&1, %{"status" => status, "completedAt" => at})
        ),
        message_id &&
          Orchestration.upsert(
            stream,
            "message",
            message_id,
            &(fun.(&1) |> Map.put("updatedAt", at))
          )
      ]
    end)

    state
  end

  @doc """
  Opens an approval prompt: a pending runtime request, the waiting approval item,
  and its node. `request_kind` is a `ProviderRequestKind` ("command", "file-change",
  "file-read", "permission"). Returns `{state, request_id}`; the runtime keeps what
  it needs to answer the provider under that id.
  """
  def open_request(state, native, request_kind, prompt) do
    ids = state.turn.ids
    driver = Entities.driver(ids)
    at = Entities.now()
    request_id = "runtime-request:#{driver}:#{native}"
    node_id = "node:approval:#{native}"
    item_id = "turn-item:approval:#{native}"
    item_ids = Map.put(ids, :node, node_id)

    commit(state, fn stream ->
      [
        Orchestration.create(
          "node",
          node_id,
          Entities.node(ids, node_id, "approval_request", "waiting", at, %{
            "runtimeRequestId" => request_id
          })
        ),
        Orchestration.create("runtime-request", request_id, %{
          "id" => request_id,
          "nodeId" => node_id,
          "providerTurnId" => Map.get(ids, :provider_turn),
          "nativeRequestRef" => Entities.provider_ref(native, driver),
          "kind" => request_kind,
          "status" => "pending",
          "responseCapability" => %{
            "type" => "live",
            "providerSessionId" => "provider-session:#{driver}:#{ids.thread}"
          },
          "createdAt" => at,
          "resolvedAt" => nil
        }),
        Orchestration.create(
          "turn-item",
          item_id,
          Entities.turn_item(
            item_ids,
            item_id,
            "approval_request",
            Orchestration.next_ordinal(stream),
            "waiting",
            at,
            %{
              "requestId" => request_id,
              "requestKind" => request_kind
            }
          )
          |> then(
            &if(is_binary(prompt) and prompt != "", do: Map.put(&1, "prompt", prompt), else: &1)
          )
        )
      ]
    end)

    {state, request_id}
  end

  @doc "Records the decision on a prompt and closes its item and node."
  def resolve_request(state, request_id, decision, status \\ "resolved") do
    at = Entities.now()

    native =
      String.replace_prefix(request_id, "runtime-request:#{Entities.driver(state.turn.ids)}:", "")

    item_status = if status == "resolved", do: "completed", else: "cancelled"

    commit(state, fn stream ->
      [
        Orchestration.upsert(
          stream,
          "runtime-request",
          request_id,
          &(&1
            |> Map.merge(%{"status" => status, "resolvedAt" => at})
            |> then(fn r -> if decision, do: Map.put(r, "decision", decision), else: r end))
        ),
        Orchestration.upsert(
          stream,
          "turn-item",
          "turn-item:approval:#{native}",
          &Map.merge(&1, %{"status" => item_status, "completedAt" => at, "updatedAt" => at})
        ),
        Orchestration.upsert(
          stream,
          "node",
          "node:approval:#{native}",
          &Map.merge(&1, %{"status" => "completed", "completedAt" => at})
        )
      ]
    end)

    state
  end

  @doc "Closes this turn's items that are still running (their node too) with `status`."
  def close_open_items(state, status) do
    at = Entities.now()

    commit(state, fn stream ->
      for {_native, %{id: item_id, node: node_id}} <- state.items,
          stream.entities["turn-item"][item_id]["status"] == "running",
          change <- [
            Orchestration.upsert(
              stream,
              "turn-item",
              item_id,
              &Map.merge(&1, %{
                "status" => status,
                "streaming" => false,
                "completedAt" => at,
                "updatedAt" => at
              })
            ),
            Orchestration.upsert(
              stream,
              "node",
              node_id,
              &Map.merge(&1, %{"status" => status, "completedAt" => at})
            )
          ],
          do: change
    end)

    state
  end

  @doc """
  Ends the run: provider turn, attempt, run, root node, and provider thread. A
  completed run also captures its workspace checkpoint (`T3.Checkpoint`).
  """
  def finish(state, status, failure) do
    ids = state.turn.ids
    at = Entities.now()
    done = %{"status" => status, "completedAt" => at}
    checkpoint = if status == "completed", do: capture_checkpoint(state.turn, at)
    # The turn may have changed the checkout; clients watching it see the result.
    T3.Vcs.Watch.refresh(state.turn.cwd)
    run_done = if checkpoint, do: Map.put(done, "checkpointId", checkpoint["id"]), else: done

    commit(state, fn stream ->
      # A turn that failed while starting has not created all of these yet.
      settle = fn kind, id, changes ->
        StreamState.get(stream, kind)[id] &&
          Orchestration.upsert(stream, kind, id, &Map.merge(&1, changes))
      end

      checkpoint_changes(stream, state.turn, checkpoint, at) ++
        [
          Map.has_key?(ids, :provider_turn) && settle.("provider-turn", ids.provider_turn, done),
          settle.("run-attempt", ids.attempt, done),
          settle.("run", ids.run, run_done),
          settle.("node", ids.root_node, done),
          settle.("provider-thread", ids.provider_thread, %{"status" => "idle", "updatedAt" => at}),
          failure && status == "failed" &&
            settle.(
              "provider-session",
              "provider-session:#{Entities.driver(ids)}:#{ids.thread}",
              %{"lastError" => failure, "updatedAt" => at}
            )
        ]
    end)
  end

  defp capture_checkpoint(%{scope_id: scope_id} = turn, at) do
    T3.Checkpoint.capture_run(
      turn.cwd,
      scope_id,
      turn.run_ordinal,
      turn.ids.run,
      turn.ids.root_node,
      turn.ids.thread,
      at
    )
  end

  defp capture_checkpoint(_turn, _at), do: nil

  # The checkpoint and the turn item that shows its changed files.
  defp checkpoint_changes(_stream, _turn, nil, _at), do: []

  defp checkpoint_changes(stream, turn, checkpoint, at) do
    item_id = item_id(turn.ids, "checkpoint:#{checkpoint["id"]}")

    [
      Orchestration.create("checkpoint", checkpoint["id"], checkpoint),
      Orchestration.create(
        "turn-item",
        item_id,
        Entities.turn_item(
          turn.ids,
          item_id,
          "checkpoint",
          Orchestration.next_ordinal(stream),
          "completed",
          at,
          %{
            "checkpointId" => checkpoint["id"],
            "scopeId" => checkpoint["scopeId"],
            "files" => checkpoint["files"]
          }
        )
      )
    ]
  end

  @doc "Buffers streamed `delta` for an item's `field`; written as an append on flush."
  def buffer(state, native, field, delta) do
    buffer = Map.update(state.buffer, {native, field}, delta, &(&1 <> delta))
    timer = state.flush_timer || Process.send_after(self(), :flush, @flush_ms)
    %{state | buffer: buffer, flush_timer: timer}
  end

  def flush(%{buffer: buffer} = state) when map_size(buffer) == 0, do: state

  def flush(state) do
    changes =
      Enum.flat_map(state.buffer, fn {{native, field}, text} ->
        %{id: item_id, message: message_id} = Map.fetch!(state.items, native)
        append = %{"a" => %{field => text}}

        [{"turn-item", item_id, append}] ++
          if(message_id && field == "text", do: [{"message", message_id, append}], else: [])
      end)

    {:ok, _} = T3.Streams.commit(state.thread_id, :thread, changes)
    if state.flush_timer, do: Process.cancel_timer(state.flush_timer)
    %{state | buffer: %{}, flush_timer: nil}
  end

  @doc "Commits the changes `fun` builds from the thread's current state; nils are skipped."
  def commit(state, fun) do
    T3.Streams.transact(state.thread_id, :thread, fn stream ->
      {fun.(stream) |> Enum.filter(&is_tuple/1), :ok}
    end)
  end
end
