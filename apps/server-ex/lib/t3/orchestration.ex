defmodule T3.Orchestration do
  @moduledoc """
  Client commands on this node's threads: start a thread, send a message, answer
  an approval, and interrupt a run, for threads whose provider is Codex, Claude, or an
  ACP agent such as OpenCode;
  plus the diffs of their checkpoints.

  Each command is decided inside the thread's stream process (`T3.Streams.transact/3`),
  so reading the thread and writing its new entities is atomic. Starting the provider
  turn happens after the commit, in the provider's runtime (`T3.Codex.ThreadRuntime`,
  `T3.Claude.ThreadRuntime`), which streams the turn back into the same log.
  """

  alias T3.Orchestration.Entities
  alias T3.{Patch, StreamState}

  @active_statuses ~w(preparing starting running waiting)

  @doc "Handles one client RPC by method name; see `packages/contracts/src/orchestrationV2.ts`."
  @spec handle(String.t(), map) :: {:ok, term} | {:error, String.t()}
  def handle("orchestration.dispatchCommand", command), do: dispatch(command)
  def handle("orchestration.launchThread", input), do: launch_thread(input)

  def handle("orchestration.getTurnDiff", %{"threadId" => thread_id} = input),
    do: turn_diff(thread_id, input["fromTurnCount"], input["toTurnCount"], input)

  def handle("orchestration.getFullThreadDiff", %{"threadId" => thread_id} = input),
    do: turn_diff(thread_id, 0, input["toTurnCount"], input)

  def handle(method, _payload), do: {:error, "#{method} is not served by this node yet"}

  defp turn_diff(thread_id, from, to, input) do
    state = T3.Streams.Server.state(T3.Streams.ensure(thread_id))
    T3.Checkpoint.turn_diff(state, thread_id, from, to, input["ignoreWhitespace"] != false)
  end

  @spec dispatch(map) :: {:ok, map} | {:error, String.t()}
  def dispatch(%{"type" => "message.dispatch", "threadId" => thread_id} = command) do
    case T3.Streams.transact(thread_id, :thread, &decide_message(&1, thread_id, command)) do
      {:ok, turn} ->
        :ok = T3.Checkpoint.baseline(turn.cwd, turn.scope_id, turn.run_ordinal - 1)
        :ok = runtime(turn.ids.instance).start_turn(thread_id, turn)
        {:ok, %{"sequence" => sequence(thread_id)}}

      {:error, _} = error ->
        error
    end
  end

  def dispatch(%{"type" => "run.interrupt", "threadId" => thread_id} = command) do
    with :ok <- interrupt_any(thread_id, command["runId"]),
         do: {:ok, %{"sequence" => sequence(thread_id)}}
  end

  def dispatch(%{"type" => "runtime-request.respond", "threadId" => thread_id} = command) do
    decision = command["decision"] || "decline"

    result =
      Enum.find_value(
        [T3.Codex.ThreadRuntime, T3.Claude.ThreadRuntime, T3.Acp.ThreadRuntime],
        {:error, "no pending request"},
        fn runtime ->
          if runtime.respond(thread_id, command["requestId"], decision) == :ok, do: :ok
        end
      )

    with :ok <- result, do: {:ok, %{"sequence" => sequence(thread_id)}}
  end

  def dispatch(%{"type" => type}), do: {:error, "#{type} is not supported by this node yet"}

  @doc "Creates a thread with its first message (`orchestration.launchThread`)."
  @spec launch_thread(map) :: {:ok, map} | {:error, String.t()}
  def launch_thread(%{"threadId" => thread_id, "initialMessage" => message} = input) do
    at = Entities.now()

    {:ok, _} =
      T3.Streams.transact(thread_id, :thread, fn state ->
        case StreamState.get(state, "thread")[thread_id] do
          nil ->
            {[{"thread", thread_id, Patch.diff(nil, Entities.thread(input, at))}],
             {:ok, :created}}

          _ ->
            {[], {:ok, :resumed}}
        end
      end)

    command =
      Map.merge(message, %{
        "type" => "message.dispatch",
        "commandId" => "#{input["commandId"]}:initial-message",
        "threadId" => thread_id,
        "createdBy" => "user",
        "creationSource" => input["creationSource"] || "web",
        "modelSelection" => input["modelSelection"]
      })

    with {:ok, _} <- dispatch(command),
         do: {:ok, %{"threadId" => thread_id, "resumed" => false}}
  end

  # The provider driver for an instance: its own id for ACP agents.
  defp driver_for("claudeAgent"), do: "claudeAgent"

  defp driver_for(instance) do
    if T3.Acp.agent?(instance), do: instance, else: "codex"
  end

  @doc "The runtime module for a provider instance."
  def runtime("claudeAgent"), do: T3.Claude.ThreadRuntime

  def runtime(instance) when is_binary(instance) and instance != "codex" do
    if T3.Acp.agent?(instance), do: T3.Acp.ThreadRuntime, else: T3.Codex.ThreadRuntime
  end

  def runtime(_codex), do: T3.Codex.ThreadRuntime

  # A thread has at most one running turn; interrupt whichever runtime holds it.
  defp interrupt_any(thread_id, run_id) do
    Enum.find_value(
      [T3.Codex.ThreadRuntime, T3.Claude.ThreadRuntime, T3.Acp.ThreadRuntime],
      {:error, "no running turn"},
      fn runtime ->
        if runtime.interrupt(thread_id, run_id) == :ok, do: :ok
      end
    )
  end

  defp sequence(thread_id), do: T3.Streams.Server.state(T3.Streams.ensure(thread_id)).seq

  # Records the user's message and a new run, and returns what the provider needs to
  # start the turn. Rejects a second run while one is active.
  defp decide_message(state, thread_id, command) do
    thread = StreamState.get(state, "thread")[thread_id]
    runs = StreamState.list(state, "run")

    cond do
      thread == nil ->
        {[], {:error, "unknown thread #{thread_id}"}}

      Enum.any?(runs, &(&1["status"] in @active_statuses)) ->
        {[], {:error, "a run is already active in this thread"}}

      true ->
        new_run(state, thread, runs, command)
    end
  end

  defp new_run(state, thread, runs, command) do
    at = Entities.now()
    thread_id = thread["id"]
    ordinal = length(runs) + 1
    selection = command["modelSelection"] || thread["modelSelection"]
    instance = selection["instanceId"] || thread["providerInstanceId"] || "codex"
    driver = driver_for(instance)
    provider_thread_id = "provider-thread:#{driver}:#{thread_id}"
    session_id = "provider-session:#{driver}:#{thread_id}"
    cwd = thread["worktreePath"] || project_root(thread["projectId"]) || File.cwd!()
    message_id = command["messageId"] || Entities.new_id("message")

    ids = %{
      driver: driver,
      instance: instance,
      thread: thread_id,
      run: Entities.new_id("run"),
      attempt: Entities.new_id("run-attempt"),
      root_node: Entities.new_id("node"),
      provider_thread: provider_thread_id,
      message: message_id
    }

    provider_thread = StreamState.get(state, "provider-thread")[provider_thread_id]
    scope_id = T3.Checkpoint.scope_id(thread_id)

    # One root checkpoint scope per thread; it follows the latest run.
    scope_change =
      if StreamState.get(state, "checkpoint-scope")[scope_id] do
        upsert(
          state,
          "checkpoint-scope",
          scope_id,
          &Map.merge(&1, %{"runId" => ids.run, "nodeId" => ids.root_node, "cwd" => cwd})
        )
      else
        create(
          "checkpoint-scope",
          scope_id,
          T3.Checkpoint.scope(thread_id, ids.run, ids.root_node, provider_thread_id, cwd, at)
        )
      end

    # An imported thread has a provider thread (its native session) but no session yet.
    session_change =
      unless StreamState.get(state, "provider-session")[session_id] do
        create(
          "provider-session",
          session_id,
          Entities.provider_session(session_id, cwd, selection["model"], at, driver, instance)
        )
      end

    provider_changes =
      if provider_thread do
        [
          session_change,
          upsert(
            state,
            "provider-thread",
            provider_thread_id,
            &Map.merge(&1, %{"lastRunOrdinal" => ordinal, "providerSessionId" => session_id})
          )
        ]
      else
        [
          session_change,
          create(
            "provider-thread",
            provider_thread_id,
            Entities.provider_thread(
              provider_thread_id,
              thread_id,
              session_id,
              ordinal,
              at,
              driver,
              instance
            )
          )
        ]
      end

    text = command["text"] || ""

    changes =
      Enum.reject(provider_changes ++ [scope_change], &is_nil/1) ++
        [
          create("run", ids.run, Entities.run(ids, ordinal, selection, at)),
          create("run-attempt", ids.attempt, Entities.attempt(ids)),
          create(
            "node",
            ids.root_node,
            Entities.node(ids, ids.root_node, "root_turn", "pending", at, %{
              "checkpointScopeId" => scope_id
            })
          ),
          create(
            "message",
            message_id,
            Entities.message(ids, message_id, "user", text, false, at)
          ),
          create(
            "turn-item",
            "turn-item:user:#{message_id}",
            Entities.turn_item(
              ids,
              "turn-item:user:#{message_id}",
              "user_message",
              next_ordinal(state),
              "completed",
              at,
              %{
                "createdBy" => command["createdBy"] || "user",
                "creationSource" => command["creationSource"] || "web",
                "messageId" => message_id,
                "inputIntent" => "turn_start",
                "text" => text,
                "attachments" => command["attachments"] || []
              }
            )
          )
        ]

    turn = %{
      ids: ids,
      run_ordinal: ordinal,
      text: text,
      cwd: cwd,
      scope_id: scope_id,
      model: selection["model"],
      runtime_mode: thread["runtimeMode"] || "full-access",
      native_thread_id: get_in(provider_thread || %{}, ["nativeThreadRef", "nativeId"])
    }

    {changes, {:ok, turn}}
  end

  @doc "The next free turn-item ordinal in a thread."
  def next_ordinal(state) do
    state
    |> StreamState.get("turn-item")
    |> Map.values()
    |> Enum.map(& &1["ordinal"])
    |> Enum.max(fn -> -1 end)
    |> Kernel.+(1)
  end

  @doc "A change creating `entity`."
  def create(kind, id, entity), do: {kind, id, Patch.diff(nil, entity)}

  @doc "A change updating an existing entity with `fun`, or `nil` when nothing changes."
  def upsert(state, kind, id, fun) do
    current = StreamState.get(state, kind)[id]

    case Patch.diff(current, fun.(current)) do
      :unchanged -> nil
      patch -> {kind, id, patch}
    end
  end

  defp project_root(nil), do: nil

  defp project_root(project_id) do
    Enum.find_value(T3.Shell.rows(), fn
      {{node, ^project_id}, {"project", row}} when node == node() -> row["workspaceRoot"]
      _ -> nil
    end)
  end
end
