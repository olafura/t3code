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
  @text_ms 400

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
      plan_id = if kind == :plan, do: "plan:#{driver}:#{native}"
      item_ids = Map.put(ids, :node, node_id)
      {node_kind, type, item_fields} = shape(kind, message_id, fields)
      item_fields = if plan_id, do: Map.put(item_fields, "planId", plan_id), else: item_fields

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
            ),
          plan_id &&
            Orchestration.create(
              "plan",
              plan_id,
              plan(ids, plan_id, node_id, "proposed_plan", "draft", %{"markdown" => ""})
            )
        ]
      end)

      item = %{id: item_id, node: node_id, message: message_id, plan: plan_id, kind: kind}
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
  defp shape(:plan, _, _), do: {"plan", "proposed_plan", %{"markdown" => "", "streaming" => true}}

  defp plan(ids, plan_id, node_id, kind, status, fields) do
    Map.merge(
      %{
        "id" => plan_id,
        "threadId" => ids.thread,
        "runId" => ids.run,
        "nodeId" => node_id,
        "kind" => kind,
        "status" => status
      },
      fields
    )
  end

  @doc """
  Completes a proposed plan (an item of kind `:plan`, whose text streamed into its
  turn item): the final `markdown` goes to the item and the plan, which becomes
  `active`, ready for the user to implement.
  """
  def finish_plan(state, native, markdown) do
    %{plan: plan_id} = Map.fetch!(state.items, native)

    state
    |> finish_item(native, "completed", fn entity ->
      Map.merge(entity, %{
        "markdown" => markdown || entity["markdown"] || "",
        "streaming" => false
      })
    end)
    |> tap(fn state ->
      commit(state, fn stream ->
        [
          Orchestration.upsert(stream, "plan", plan_id, fn plan ->
            Map.merge(plan, %{
              "status" => "active",
              "markdown" =>
                markdown ||
                  get_in(stream.entities, [
                    "turn-item",
                    item_id(state.turn.ids, native),
                    "markdown"
                  ]) || ""
            })
          end)
        ]
      end)
    end)
  end

  @doc """
  Writes a todo list (`OrchestrationV2PlanStep`s) as a plan with its turn item and
  node, creating them the first time and replacing the steps after that. The plan
  is complete once every step is.
  """
  def write_todo(state, native, steps, explanation \\ nil) do
    ids = state.turn.ids
    driver = Entities.driver(ids)
    at = Entities.now()
    plan_id = "plan:#{driver}:#{native}"
    item_id = item_id(ids, native)
    node_id = "node:todo:#{driver}:#{native}"
    done = steps != [] and Enum.all?(steps, &(&1["status"] == "completed"))

    fields =
      %{"steps" => steps}
      |> then(&if(explanation, do: Map.put(&1, "explanation", explanation), else: &1))

    # The item is a snapshot of the list; the plan's status tracks its progress.
    item_status = "completed"

    commit(state, fn stream ->
      if stream.entities["plan"][plan_id] do
        [
          Orchestration.upsert(
            stream,
            "plan",
            plan_id,
            &Map.merge(&1, Map.put(fields, "status", if(done, do: "completed", else: "active")))
          ),
          Orchestration.upsert(
            stream,
            "turn-item",
            item_id,
            &Map.merge(&1, Map.merge(fields, %{"status" => item_status, "updatedAt" => at}))
          )
        ]
      else
        item_ids = Map.put(ids, :node, node_id)

        [
          Orchestration.create(
            "node",
            node_id,
            Entities.node(ids, node_id, "todo_list", "completed", at, %{
              "nativeItemRef" => Entities.provider_ref(native, driver)
            })
          ),
          Orchestration.create(
            "plan",
            plan_id,
            plan(
              ids,
              plan_id,
              node_id,
              "todo_list",
              if(done, do: "completed", else: "active"),
              fields
            )
          ),
          Orchestration.create(
            "turn-item",
            item_id,
            Entities.turn_item(
              item_ids,
              item_id,
              "todo_list",
              Orchestration.next_ordinal(stream),
              item_status,
              at,
              Map.put(fields, "planId", plan_id)
            )
          )
        ]
      end
    end)

    state
  end

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
  "file-read", "permission"). `options` are the `ProviderApprovalOption`s the
  provider can honour, when it says. Returns `{state, request_id}`; the runtime
  keeps what it needs to answer the provider under that id.
  """
  def open_request(state, native, request_kind, prompt, options \\ nil),
    do: open(state, native, {:approval, request_kind, prompt, options})

  @doc """
  Opens questions for the user (`OrchestrationV2UserInputQuestion`s): a pending
  `user_input` request and its waiting `user_input_request` item. Answers arrive
  through `resolve_request/4` like approvals. Returns `{state, request_id}`.
  """
  def open_question(state, native, questions), do: open(state, native, {:questions, questions})

  defp open(state, native, what) do
    ids = state.turn.ids
    driver = Entities.driver(ids)
    at = Entities.now()
    request_id = "runtime-request:#{driver}:#{native}"
    node_id = "node:approval:#{native}"
    item_id = "turn-item:approval:#{native}"
    item_ids = Map.put(ids, :node, node_id)

    {node_kind, request_kind, item_fields} =
      case what do
        {:approval, kind, prompt, options} ->
          fields = %{"requestId" => request_id, "requestKind" => kind}
          fields = if is_list(options), do: Map.put(fields, "options", options), else: fields

          {"approval_request", kind,
           if(is_binary(prompt) and prompt != "",
             do: Map.put(fields, "prompt", prompt),
             else: fields
           )}

        {:questions, questions} ->
          {"user_input_request", "user_input",
           %{"requestId" => request_id, "questions" => questions}}
      end

    commit(state, fn stream ->
      [
        Orchestration.create(
          "node",
          node_id,
          Entities.node(ids, node_id, node_kind, "waiting", at, %{
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
            node_kind,
            Orchestration.next_ordinal(stream),
            "waiting",
            at,
            item_fields
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
            |> Map.merge(response_fields(decision)))
        ),
        Orchestration.upsert(
          stream,
          "turn-item",
          "turn-item:approval:#{native}",
          &(&1
            |> Map.merge(%{"status" => item_status, "completedAt" => at, "updatedAt" => at})
            |> Map.merge(question_answer(decision)))
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

  # What the user answered a question with, attachments included, for the question item.
  defp question_answer(%{"questionAnswer" => answer}), do: %{"questionAnswer" => answer}
  defp question_answer(_decision), do: %{}

  # A decision string, or a response's `decision`/`answers`.
  defp response_fields(nil), do: %{}
  defp response_fields(decision) when is_binary(decision), do: %{"decision" => decision}
  defp response_fields(%{} = response), do: Map.take(response, ["decision", "answers"])

  @doc "Closes this turn's items that are still running (their node too) with `status`."
  def close_open_items(state, status) do
    at = Entities.now()

    commit(state, fn stream ->
      for {_native, %{id: item_id, node: node_id} = item} <- state.items,
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
            ),
            # An assistant item's message stops streaming with it.
            item[:message] &&
              Orchestration.upsert(
                stream,
                "message",
                item.message,
                &Map.merge(&1, %{"streaming" => false, "updatedAt" => at})
              )
          ],
          change,
          do: change
    end)

    state
  end

  @doc """
  Ends the run: provider turn, attempt, run, root node, and provider thread. A
  completed run also captures its workspace checkpoint (`T3.Checkpoint`). The
  thread's next queued message then starts (`T3.Orchestration.start_next/1`).
  """
  def finish(state, status, failure) do
    ids = state.turn.ids
    at = Entities.now()
    done = %{"status" => status, "completedAt" => at}
    checkpoint = if status == "completed", do: capture_checkpoint(state.turn, at)
    # The turn may have changed the checkout; clients watching it see the result.
    T3.Vcs.Watch.refresh(state.turn.cwd)
    T3.Workspace.invalidate(state.turn.cwd)
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

    # The thread is idle now: its next queued message can start. Off this process,
    # since starting a turn calls back into the runtime that is finishing this one.
    thread_id = state.thread_id

    Task.start(fn ->
      Orchestration.start_next(thread_id)
      # A delegated task reports back to the thread that asked for it.
      T3.Orchestration.Delegation.finished(thread_id, ids.run, status)
    end)

    :ok
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

  @doc """
  Writes buffered text. `:all` (item ends, prompts, the turn's end) writes
  everything; `:timer` holds assistant and reasoning text back by the project's
  `responseStreamingMode`, as the Node server does: "paragraph" writes finished
  paragraphs and closed code blocks at most every 400 ms, "turn" writes nothing
  until a boundary. Tool output and plans stream as they come.
  """
  def flush(state, how \\ :all)

  def flush(%{buffer: buffer} = state, _how) when map_size(buffer) == 0, do: state

  def flush(state, how) do
    now = System.monotonic_time(:millisecond)
    mode = Map.get(state.turn || %{}, :streaming_mode, "paragraph")
    streamed = Map.get(state, :streamed, %{})

    {writes, held, streamed} =
      Enum.reduce(state.buffer, {[], %{}, streamed}, fn {key, pending},
                                                        {writes, held, streamed} ->
        {native, field} = key
        committed = streamed[key] || ""

        cond do
          how == :all or not prose?(state, native, field) ->
            {[{key, pending} | writes], held, Map.put(streamed, key, committed <> pending)}

          mode == "turn" or recent?(state, now) ->
            {writes, Map.put(held, key, pending), streamed}

          true ->
            {ready, _rest} = split_ready(committed <> pending)

            if byte_size(ready) > byte_size(committed) do
              out =
                binary_part(ready, byte_size(committed), byte_size(ready) - byte_size(committed))

              rest = binary_part(pending, byte_size(out), byte_size(pending) - byte_size(out))
              held = if rest == "", do: held, else: Map.put(held, key, rest)
              {[{key, out} | writes], held, Map.put(streamed, key, ready)}
            else
              {writes, Map.put(held, key, pending), streamed}
            end
        end
      end)

    changes =
      Enum.flat_map(writes, fn {{native, field}, text} ->
        %{id: item_id, message: message_id} = Map.fetch!(state.items, native)
        append = %{"a" => %{field => text}}

        [{"turn-item", item_id, append}] ++
          if(message_id && field == "text", do: [{"message", message_id, append}], else: [])
      end)

    if changes != [], do: {:ok, _} = T3.Streams.commit(state.thread_id, :thread, changes)
    if state.flush_timer, do: Process.cancel_timer(state.flush_timer)

    wrote_prose = Enum.any?(writes, fn {{native, field}, _} -> prose?(state, native, field) end)

    # Held paragraphs get another look once the throttle allows one.
    timer =
      if held != %{} and mode == "paragraph",
        do: Process.send_after(self(), :flush, @text_ms)

    state
    |> Map.merge(%{buffer: held, flush_timer: timer, streamed: streamed})
    |> then(&if(wrote_prose and how == :timer, do: Map.put(&1, :text_at, now), else: &1))
  end

  defp recent?(state, now) do
    case Map.get(state, :text_at) do
      nil -> false
      at -> now - at < @text_ms
    end
  end

  defp prose?(state, native, "text"),
    do: match?(%{kind: k} when k in [:assistant, :reasoning], state.items[native])

  defp prose?(_state, _native, _field), do: false

  @doc """
  Splits text at its last blank line or closing code fence outside an open
  fence: `{ready, rest}`, where `ready` will not change shape as more arrives.
  Only whole lines count, so a partial line is never delivered.
  """
  def split_ready(text) do
    {boundary, _fence, _offset} =
      text
      |> String.split("\n")
      # The last piece has no newline after it yet.
      |> Enum.drop(-1)
      |> Enum.reduce({0, nil, 0}, fn raw, {boundary, fence, offset} ->
        line = String.replace(raw, ~r/[ \t\r]+$/, "")
        next = offset + byte_size(raw) + 1

        case Regex.run(~r/^( *)(`{3,}|~{3,})/, line) do
          [_, indent, marker] when fence == nil ->
            {boundary, {marker, byte_size(indent)}, next}

          [_, indent, marker] ->
            {open, open_indent} = fence

            if String.first(marker) == String.first(open) and
                 byte_size(marker) >= byte_size(open) and
                 byte_size(indent) <= open_indent + 3 and
                 byte_size(line) == byte_size(indent) + byte_size(marker),
               do: {next, nil, next},
               else: {boundary, fence, next}

          nil ->
            if fence == nil and offset > 0 and Regex.match?(~r/^[ \t]*$/, line),
              do: {next, nil, next},
              else: {boundary, fence, next}
        end
      end)

    {binary_part(text, 0, boundary), binary_part(text, boundary, byte_size(text) - boundary)}
  end

  @doc "Commits the changes `fun` builds from the thread's current state; nils are skipped."
  def commit(state, fun) do
    T3.Streams.transact(state.thread_id, :thread, fn stream ->
      {fun.(stream) |> Enum.filter(&is_tuple/1), :ok}
    end)
  end
end
