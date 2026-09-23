defmodule T3.Acp.ThreadRuntime do
  @moduledoc """
  Runs one thread's turns on an Agent Client Protocol agent (OpenCode's
  `opencode acp`, a registry agent, or any other instance in `T3.Acp.instances/0`) and writes them into
  the thread's log.

  One agent process serves the thread: `initialize`, then `session/new`, or
  `session/resume` (else `session/load`) on the recorded session id when the
  thread already has one. Each message is a `session/prompt`, run off the process
  since it lasts the whole turn; its `session/update` notifications stream thoughts,
  answers, and tool calls into items. Permission requests become approvals, which
  full-access threads grant at once. Interrupt is `session/cancel`.
  """

  use GenServer, restart: :temporary

  require Logger

  import T3.Orchestration.TurnWriter

  alias T3.JsonRpc.Connection
  alias T3.Orchestration
  alias T3.Orchestration.Entities

  @state_version 2
  @registry T3.Acp.Registry

  @spec start_turn(String.t(), map) :: :ok
  def start_turn(thread_id, turn),
    do: thread_id |> ensure() |> GenServer.call({:start_turn, turn}, 120_000)

  @spec interrupt(String.t(), String.t() | nil) :: :ok | {:error, String.t()}
  def interrupt(thread_id, _run_id) do
    case lookup(thread_id) do
      nil -> {:error, "no active ACP turn in this thread"}
      pid -> GenServer.call(pid, :interrupt, 15_000)
    end
  end

  @doc "ACP has no way to add to a running prompt."
  def steer(_thread_id, _run_id, _text), do: {:error, "ACP agents cannot be steered"}

  @spec respond(String.t(), String.t(), map) :: :ok | {:error, String.t()}
  def respond(thread_id, request_id, response) do
    case lookup(thread_id) do
      nil -> {:error, "no pending request"}
      pid -> GenServer.call(pid, {:respond, request_id, response["decision"] || "decline"})
    end
  end

  def start_link(thread_id),
    do:
      GenServer.start_link(__MODULE__, thread_id, name: {:via, Registry, {@registry, thread_id}})

  defp lookup(thread_id) do
    case Registry.lookup(@registry, thread_id) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  defp ensure(thread_id) do
    case DynamicSupervisor.start_child(T3.Codex.Supervisor, {__MODULE__, thread_id}) do
      {:ok, pid} -> pid
      {:error, {:already_started, pid}} -> pid
    end
  end

  # --- server ------------------------------------------------------------------

  @impl true
  def init(thread_id) do
    Process.flag(:trap_exit, true)

    {:ok,
     %{
       v: @state_version,
       thread_id: thread_id,
       conn: nil,
       agent: nil,
       mode: nil,
       capabilities: %{},
       session_id: nil,
       model: nil,
       turn: nil,
       prompt: nil,
       items: %{},
       buffer: %{},
       flush_timer: nil,
       interrupted: false,
       # Updates `session/load` replays are history, not this turn.
       replaying: false,
       # Open permission prompts: request id -> {rpc id, options}.
       requests: %{}
     }}
  end

  @impl true
  def handle_call({:start_turn, turn}, _from, state) do
    driver = turn.ids.driver
    ids = Map.put(turn.ids, :provider_turn, "provider-turn:#{driver}:#{turn.ids.run}")
    turn = %{turn | ids: ids}
    state = %{state | turn: turn, items: %{}, interrupted: false}

    with {:ok, state} <- ensure_session(state, turn),
         state = set_model(state, turn.model) do
      started(state)
      conn = state.conn
      session_id = state.session_id
      prompt = acp_prompt(turn, state.capabilities)

      task =
        Task.async(fn ->
          Connection.call(
            conn,
            "session/prompt",
            %{"sessionId" => session_id, "prompt" => prompt},
            :infinity
          )
        end)

      {:reply, :ok, %{state | prompt: task.ref}}
    else
      {:error, reason, state} ->
        Logger.warning("#{driver} turn failed to start: #{inspect(reason)}")
        finish(state, "failed", "#{T3.Acp.label(driver)} could not start: #{format(reason)}")
        {:reply, :ok, %{state | turn: nil}}
    end
  end

  def handle_call(:interrupt, _from, %{prompt: ref} = state) when ref != nil do
    Connection.notify(state.conn, "session/cancel", %{"sessionId" => state.session_id})
    state = cancel_requests(state)
    {:reply, :ok, %{state | interrupted: true}}
  end

  def handle_call(:interrupt, _from, state), do: {:reply, {:error, "no running turn"}, state}

  def handle_call({:respond, request_id, decision}, _from, state) do
    case Map.pop(state.requests, request_id) do
      {nil, _} ->
        {:reply, {:error, "no pending request #{request_id}"}, state}

      {{rpc_id, options}, requests} ->
        Connection.respond(state.conn, rpc_id, {:ok, %{"outcome" => outcome(options, decision)}})
        state = resolve_request(%{state | requests: requests}, request_id, decision)
        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_info(
        {:json_rpc, _conn, {:notification, "session/update", %{"update" => update}}},
        state
      ) do
    if state.replaying or state.turn == nil,
      do: {:noreply, state},
      else: {:noreply, update(update, state)}
  end

  def handle_info({:json_rpc, conn, {:request, id, "session/request_permission", params}}, state) do
    {:noreply, permission(conn, id, params, state)}
  end

  # This client offers no file system or terminal; say so rather than hang.
  def handle_info({:json_rpc, conn, {:request, id, method, _params}}, state) do
    Connection.respond(
      conn,
      id,
      {:error, %{"code" => -32601, "message" => "#{method} is not supported"}}
    )

    {:noreply, state}
  end

  def handle_info({ref, result}, %{prompt: ref} = state) do
    Process.demonitor(ref, [:flush])

    {status, failure} =
      case result do
        _ when state.interrupted -> {"interrupted", nil}
        {:ok, %{"stopReason" => "cancelled"}} -> {"interrupted", nil}
        {:ok, %{"stopReason" => _}} -> {"completed", nil}
        {:error, %{"message" => message}} -> {"failed", message}
        {:error, reason} -> {"failed", format(reason)}
      end

    {:noreply, end_turn(%{state | prompt: nil}, status, failure)}
  end

  def handle_info({:EXIT, conn, _reason}, %{conn: conn} = state) do
    state =
      if state.turn,
        do: end_turn(state, "failed", "#{T3.Acp.label(state.agent)} exited"),
        else: state

    {:noreply, %{state | conn: nil, session_id: nil, prompt: nil}}
  end

  def handle_info(:flush, state), do: {:noreply, flush(%{state | flush_timer: nil})}
  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def code_change(_old, state, _extra), do: {:ok, migrate(state)}

  # Every older state shape migrates forward here; v2 added the agent's mode.
  defp migrate(%{v: @state_version} = state), do: state
  defp migrate(%{v: 1} = state), do: state |> Map.put_new(:mode, nil) |> Map.put(:v, 2)

  # --- session -------------------------------------------------------------------

  # The agent's permission mode is set when it starts, so a new mode means a new process.
  defp ensure_session(%{conn: conn, session_id: sid, agent: agent, mode: mode} = state, turn)
       when conn != nil and sid != nil and agent == turn.ids.driver and mode == turn.runtime_mode,
       do: {:ok, state}

  defp ensure_session(state, turn) do
    driver = turn.ids.driver
    if state.conn, do: Connection.stop(state.conn)

    with {:ok, command, env} <- T3.Acp.command(driver, turn.runtime_mode),
         {:ok, conn} <-
           Connection.start_link(
             cmd: command,
             handler: self(),
             cd: turn.cwd,
             env: env,
             dialect: :v2
           ),
         {:ok, init} <-
           Connection.call(conn, "initialize", %{
             "protocolVersion" => 1,
             "clientCapabilities" => %{
               "fs" => %{"readTextFile" => false, "writeTextFile" => false},
               "terminal" => false
             },
             "clientInfo" => %{"name" => "t3code", "version" => "0.1.0"}
           }),
         state = %{
           state
           | conn: conn,
             agent: driver,
             mode: turn.runtime_mode,
             capabilities: init["agentCapabilities"] || %{}
         },
         {:ok, session_id, state} <- open_session(state, turn) do
      if session_id != turn.native_thread_id, do: record_session(state, session_id)
      {:ok, %{state | session_id: session_id}}
    else
      {:error, reason} -> {:error, reason, state}
      {:error, reason, state} -> {:error, reason, state}
    end
  end

  # Continue the recorded session when the agent can; otherwise start a new one.
  defp open_session(state, %{native_thread_id: native} = turn) when is_binary(native) do
    params = %{"sessionId" => native, "cwd" => turn.cwd, "mcpServers" => []}
    caps = state.capabilities

    cond do
      is_map(get_in(caps, ["sessionCapabilities", "resume"])) ->
        case Connection.call(state.conn, "session/resume", params, 60_000) do
          {:ok, result} -> {:ok, native, remember_model(state, result)}
          {:error, _} -> new_session(state, turn)
        end

      caps["loadSession"] == true ->
        state = %{state | replaying: true}
        result = Connection.call(state.conn, "session/load", params, 120_000)
        state = %{state | replaying: false}

        case result do
          {:ok, result} -> {:ok, native, remember_model(state, result || %{})}
          {:error, _} -> new_session(state, turn)
        end

      true ->
        new_session(state, turn)
    end
  end

  defp open_session(state, turn), do: new_session(state, turn)

  defp new_session(state, turn) do
    case Connection.call(
           state.conn,
           "session/new",
           %{"cwd" => turn.cwd, "mcpServers" => []},
           60_000
         ) do
      {:ok, %{"sessionId" => id} = result} -> {:ok, id, remember_model(state, result)}
      {:ok, other} -> {:error, {:unexpected, other}, state}
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp remember_model(state, result) do
    case Enum.find(result["configOptions"] || [], &(&1["id"] == "model")) do
      %{"currentValue" => model} -> %{state | model: model}
      _ -> state
    end
  end

  defp set_model(state, model) when is_binary(model) and model != "" and model != state.model do
    case Connection.call(state.conn, "session/set_config_option", %{
           "sessionId" => state.session_id,
           "configId" => "model",
           "value" => model
         }) do
      {:ok, _} ->
        %{state | model: model}

      {:error, reason} ->
        Logger.warning("could not select #{model}: #{inspect(reason)}")
        state
    end
  end

  defp set_model(state, _model), do: state

  defp record_session(state, session_id) do
    ids = state.turn.ids

    commit(state, fn stream ->
      [
        Orchestration.upsert(
          stream,
          "provider-thread",
          ids.provider_thread,
          &Map.put(&1, "nativeThreadRef", Entities.provider_ref(session_id, ids.driver))
        )
      ]
    end)
  end

  defp started(state) do
    %{turn: turn} = state
    ids = turn.ids
    at = Entities.now()

    commit(state, fn stream ->
      [
        Orchestration.create(
          "provider-turn",
          ids.provider_turn,
          Entities.provider_turn(ids, nil, turn.run_ordinal, at)
        ),
        Orchestration.upsert(
          stream,
          "run-attempt",
          ids.attempt,
          &Map.merge(&1, %{
            "status" => "running",
            "providerTurnId" => ids.provider_turn,
            "startedAt" => at
          })
        ),
        Orchestration.upsert(
          stream,
          "run",
          ids.run,
          &Map.merge(&1, %{"status" => "running", "startedAt" => at})
        ),
        Orchestration.upsert(
          stream,
          "node",
          ids.root_node,
          &Map.merge(&1, %{"status" => "running", "providerTurnId" => ids.provider_turn})
        ),
        Orchestration.upsert(
          stream,
          "provider-thread",
          ids.provider_thread,
          &Map.merge(&1, %{"status" => "active", "updatedAt" => at})
        ),
        Orchestration.upsert(
          stream,
          "thread",
          ids.thread,
          &Map.put(&1, "activeProviderThreadId", ids.provider_thread)
        )
      ]
    end)
  end

  # --- updates -------------------------------------------------------------------

  defp update(%{"sessionUpdate" => "agent_message_chunk"} = u, state),
    do: chunk(state, u, :assistant)

  defp update(%{"sessionUpdate" => "agent_thought_chunk"} = u, state),
    do: chunk(state, u, :reasoning)

  defp update(%{"sessionUpdate" => "tool_call", "toolCallId" => id} = call, state) do
    {kind, fields} = tool_shape(call)
    state = state |> flush() |> ensure_item(id, kind, fields)
    if call["status"] in ["completed", "failed"], do: finish_tool(state, id, call), else: state
  end

  defp update(%{"sessionUpdate" => "tool_call_update", "toolCallId" => id} = call, state) do
    state =
      if Map.has_key?(state.items, id),
        do: state,
        else:
          (fn {kind, fields} -> ensure_item(flush(state), id, kind, fields) end).(
            tool_shape(call)
          )

    if call["status"] in ["completed", "failed"], do: finish_tool(state, id, call), else: state
  end

  defp update(_update, state), do: state

  defp chunk(state, %{"content" => %{"type" => "text", "text" => text}} = u, kind) do
    key = "#{kind}:#{u["messageId"] || "current"}"
    state |> ensure_item(key, kind) |> buffer(key, "text", text)
  end

  defp chunk(state, _u, _kind), do: state

  defp tool_shape(call) do
    input = call["rawInput"] || %{}
    path = get_in(call, ["locations", Access.at(0), "path"])

    case call["kind"] do
      "execute" ->
        {:command, %{"input" => command_text(input, call["title"]), "output" => ""}}

      kind when kind in ["edit", "delete", "move"] ->
        {:file, %{"fileName" => path || call["title"] || "file"}}

      "fetch" ->
        {:web, %{"patterns" => Enum.filter([input["url"], input["query"]], &is_binary/1)}}

      _ ->
        {:tool, %{"toolName" => call["title"] || call["kind"] || "tool", "input" => input}}
    end
  end

  defp command_text(%{"command" => command}, _title) when is_binary(command), do: command
  defp command_text(%{"command" => [_ | _] = argv}, _title), do: Enum.join(argv, " ")
  defp command_text(_input, title), do: title || ""

  defp finish_tool(state, id, call) do
    %{kind: kind} = state.items[id]
    status = if call["status"] == "failed", do: "failed", else: "completed"
    output = content_text(call["content"]) || raw_output(call["rawOutput"])

    finish_item(state, id, status, fn entity ->
      case kind do
        :command ->
          entity
          |> Map.put("output", output || "")
          |> then(
            &if(call["rawInput"],
              do: Map.put(&1, "input", command_text(call["rawInput"], entity["input"])),
              else: &1
            )
          )

        :file ->
          Map.put(entity, "diffStr", output || "")

        :tool ->
          entity
          |> Map.put("output", output || "")
          |> then(&if(call["rawInput"], do: Map.put(&1, "input", call["rawInput"]), else: &1))

        _ ->
          entity
      end
    end)
  end

  # Tool content: text blocks, and diffs as a small before/after.
  defp content_text([_ | _] = content) do
    content
    |> Enum.map(fn
      %{"type" => "content", "content" => %{"type" => "text", "text" => text}} ->
        text

      %{"type" => "diff", "path" => path, "newText" => new} = diff ->
        "#{path}\n--- before\n#{diff["oldText"] || ""}\n+++ after\n#{new}"

      _ ->
        nil
    end)
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      parts -> Enum.join(parts, "\n")
    end
  end

  defp content_text(_), do: nil

  defp raw_output(%{"output" => output}) when is_binary(output), do: output
  defp raw_output(_), do: nil

  # --- permissions ---------------------------------------------------------------

  # Full-access threads allow without asking; others ask the user.
  defp permission(conn, id, params, %{turn: nil} = state) do
    Connection.respond(conn, id, {:ok, %{"outcome" => %{"outcome" => "cancelled"}}})
    _ = params
    state
  end

  defp permission(conn, id, params, state) do
    options = params["options"] || []
    call = params["toolCall"] || %{}

    if state.turn.runtime_mode == "full-access" do
      Connection.respond(conn, id, {:ok, %{"outcome" => outcome(options, "accept")}})
      state
    else
      kind =
        case call["kind"] do
          "execute" -> "command"
          k when k in ["edit", "delete", "move"] -> "file-change"
          k when k in ["read", "search"] -> "file-read"
          _ -> "permission"
        end

      prompt = command_text(call["rawInput"] || %{}, call["title"])
      {state, request_id} = open_request(flush(state), "#{id}", kind, prompt)
      %{state | requests: Map.put(state.requests, request_id, {id, options})}
    end
  end

  # The agent's option for a `ProviderApprovalDecision`, or a cancellation.
  defp outcome(options, decision) do
    wanted =
      case decision do
        "accept" -> ["allow_once", "allow_always"]
        d when d in ["acceptForSession", "acceptAlways"] -> ["allow_always", "allow_once"]
        "decline" -> ["reject_once", "reject_always"]
        _ -> []
      end

    case Enum.find_value(wanted, fn kind -> Enum.find(options, &(&1["kind"] == kind)) end) do
      %{"optionId" => option} -> %{"outcome" => "selected", "optionId" => option}
      nil -> %{"outcome" => "cancelled"}
    end
  end

  defp cancel_requests(state) do
    Enum.reduce(state.requests, %{state | requests: %{}}, fn {request_id, {rpc_id, _}}, state ->
      Connection.respond(state.conn, rpc_id, {:ok, %{"outcome" => %{"outcome" => "cancelled"}}})
      resolve_request(state, request_id, nil, "cancelled")
    end)
  end

  defp end_turn(state, status, failure) do
    state = state |> flush() |> close_open_items(status) |> cancel_requests()
    finish(state, status, failure)
    %{state | turn: nil, items: %{}}
  end

  # The message, with where its files are; images inline when the agent takes them.
  defp acp_prompt(turn, capabilities) do
    attachments = Map.get(turn, :attachments, [])
    text = [%{"type" => "text", "text" => T3.Attachments.prompt_text(turn.text, attachments)}]

    if get_in(capabilities || %{}, ["promptCapabilities", "image"]) == true,
      do:
        text ++
          for(
            {mime, data} <- T3.Attachments.native_images(attachments),
            do: %{"type" => "image", "mimeType" => mime, "data" => data}
          ),
      else: text
  end

  defp format(reason) when is_binary(reason), do: reason
  defp format(%{"message" => message}), do: message
  defp format(reason), do: inspect(reason)
end
