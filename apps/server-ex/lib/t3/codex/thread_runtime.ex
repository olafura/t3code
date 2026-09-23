defmodule T3.Codex.ThreadRuntime do
  @moduledoc """
  Runs one thread's Codex turns through `codex app-server` and writes them into the
  thread's log.

  The process owns the app-server connection for its thread. A turn starts with
  `thread/start` (or `thread/resume` for a thread Codex already knows) and
  `turn/start`; the app-server's notifications then become entity patches.
  Streamed text and command output are written as appends (`T3.Orchestration.TurnWriter`),
  so a long answer costs its new bytes, not its whole length, per update.
  """

  use GenServer, restart: :temporary

  require Logger

  import T3.Orchestration.TurnWriter

  alias T3.Orchestration
  alias T3.Orchestration.Entities
  alias T3.JsonRpc.Connection

  @state_version 1

  # runtimeMode -> {approvalPolicy, sandboxPolicy type}, as the Node adapter maps it.
  @runtime_policies %{
    "approval-required" => {"untrusted", "readOnly"},
    "auto-accept-edits" => {"on-request", "workspaceWrite"},
    "auto" => {"on-request", "workspaceWrite"},
    "full-access" => {"never", "dangerFullAccess"}
  }

  def driver, do: "codex"

  @spec start_turn(String.t(), map) :: :ok
  def start_turn(thread_id, turn),
    do: thread_id |> ensure() |> GenServer.call({:start_turn, turn}, 60_000)

  @spec interrupt(String.t(), String.t() | nil) :: :ok | {:error, String.t()}
  def interrupt(thread_id, _run_id) do
    case Registry.lookup(T3.Codex.Registry, thread_id) do
      [{pid, _}] -> GenServer.call(pid, :interrupt, 15_000)
      [] -> {:error, "no active Codex turn in this thread"}
    end
  end

  @doc "Adds a message to the running turn of `run_id` (`turn/steer`)."
  @spec steer(String.t(), String.t(), String.t()) :: :ok | {:error, String.t()}
  def steer(thread_id, run_id, text) do
    case Registry.lookup(T3.Codex.Registry, thread_id) do
      [{pid, _}] -> GenServer.call(pid, {:steer, run_id, text}, 30_000)
      [] -> {:error, "no running turn"}
    end
  end

  @doc """
  Answers a prompt: an approval's `%{"decision" => ProviderApprovalDecision}`,
  questions' `%{"answers" => answers}`, or `%{"dismissed" => true}`.
  """
  @spec respond(String.t(), String.t(), map) :: :ok | {:error, String.t()}
  def respond(thread_id, request_id, response) do
    case Registry.lookup(T3.Codex.Registry, thread_id) do
      [{pid, _}] -> GenServer.call(pid, {:respond, request_id, response})
      [] -> {:error, "no pending request"}
    end
  end

  @doc "Drops the last `drop` turns of the thread's Codex conversation (`thread/rollback`)."
  @spec rollback(String.t(), map) :: {:ok, map} | {:error, String.t()}
  def rollback(thread_id, plan),
    do: thread_id |> ensure() |> GenServer.call({:rollback, plan}, 60_000)

  @doc """
  `provider.uploadFeedback`: sends Codex a bug report with its logs for this
  thread's provider thread. Needs the thread's session to be running.
  """
  def upload_feedback(thread_id, reason) do
    case Registry.lookup(T3.Codex.Registry, thread_id) do
      [{pid, _}] -> GenServer.call(pid, {:upload_feedback, reason}, 60_000)
      [] -> {:error, "The provider session is no longer running. Send a message first."}
    end
  end

  def start_link(thread_id),
    do:
      GenServer.start_link(__MODULE__, thread_id,
        name: {:via, Registry, {T3.Codex.Registry, thread_id}}
      )

  defp ensure(thread_id) do
    case DynamicSupervisor.start_child(T3.Codex.Supervisor, {__MODULE__, thread_id}) do
      {:ok, pid} -> pid
      {:error, {:already_started, pid}} -> pid
    end
  end

  # --- server ------------------------------------------------------------------

  @impl true
  def init(thread_id) do
    {:ok,
     %{
       v: @state_version,
       thread_id: thread_id,
       conn: nil,
       native_thread_id: nil,
       turn: nil,
       items: %{},
       buffer: %{},
       flush_timer: nil,
       failure: nil,
       # Open approval prompts: request id -> the app-server request to answer.
       requests: %{}
     }}
  end

  @impl true
  def handle_call({:start_turn, turn}, _from, state) do
    state = %{state | turn: turn, items: %{}, failure: nil}

    case begin_turn(state, turn) do
      {:ok, state} ->
        {:reply, :ok, state}

      {:error, reason, state} ->
        Logger.warning("codex turn failed to start: #{inspect(reason)}")
        finish(state, "failed", "Codex could not start: #{inspect(reason)}")
        {:reply, :ok, %{state | turn: nil}}
    end
  end

  def handle_call(:interrupt, _from, %{turn: %{native_turn_id: turn_id}} = state)
      when is_binary(turn_id) do
    Connection.call(state.conn, "turn/interrupt", %{
      "threadId" => state.native_thread_id,
      "turnId" => turn_id
    })

    {:reply, :ok, state}
  end

  def handle_call(:interrupt, _from, state), do: {:reply, {:error, "no running turn"}, state}

  # Codex refuses the steer if its turn has moved on, so a late steer fails cleanly.
  def handle_call(
        {:steer, run_id, text},
        _from,
        %{turn: %{ids: %{run: run_id}, native_turn_id: turn_id}} = state
      ) do
    params = %{
      "threadId" => state.native_thread_id,
      "expectedTurnId" => turn_id,
      "input" => [%{"type" => "text", "text" => text}]
    }

    case Connection.call(state.conn, "turn/steer", params) do
      {:ok, _} -> {:reply, :ok, state}
      {:error, reason} -> {:reply, {:error, inspect(reason)}, state}
    end
  end

  def handle_call({:rollback, _plan}, _from, %{turn: turn} = state) when turn != nil,
    do: {:reply, {:error, "Interrupt the current turn before rewinding."}, state}

  def handle_call({:rollback, plan}, _from, state) do
    turn = %{cwd: plan.cwd, model: plan.model, native_thread_id: plan.native_thread_id}

    with {:ok, state} <- connect(state, turn),
         {:ok, state} <- ensure_native_thread(state, turn),
         {:ok, %{"thread" => %{"id" => id}}} <- rewind(state, plan) do
      {:reply, {:ok, %{"nativeThreadRef" => Entities.provider_ref(id)}},
       %{state | native_thread_id: id}}
    else
      {:error, reason, state} -> {:reply, {:error, rpc_message(reason)}, state}
      {:error, reason} -> {:reply, {:error, rpc_message(reason)}, state}
    end
  end

  def handle_call({:upload_feedback, reason}, _from, state) do
    params =
      %{"classification" => "bug", "includeLogs" => true, "threadId" => state.native_thread_id}
      |> then(&if(is_binary(reason), do: Map.put(&1, "reason", reason), else: &1))

    reply =
      with conn when conn != nil <- state.conn,
           true <- is_binary(state.native_thread_id),
           {:ok, %{"threadId" => id}} <- Connection.call(conn, "feedback/upload", params) do
        {:ok, %{"feedbackId" => id}}
      else
        {:error, reason} -> {:error, rpc_message(reason)}
        _ -> {:error, "The provider session is no longer running. Send a message first."}
      end

    {:reply, reply, state}
  end

  def handle_call({:steer, _run_id, _text}, _from, state),
    do: {:reply, {:error, "no running turn"}, state}

  def handle_call({:respond, request_id, response}, _from, state) do
    case Map.pop(state.requests, request_id) do
      {nil, _} ->
        {:reply, {:error, "no pending request #{request_id}"}, state}

      {{:question, rpc_id, question_ids}, requests} ->
        answers = if response["dismissed"], do: %{}, else: response["answers"] || %{}

        Connection.respond(
          state.conn,
          rpc_id,
          {:ok, %{"answers" => codex_answers(answers, question_ids)}}
        )

        status = if response["dismissed"], do: "cancelled", else: "resolved"
        state = resolve_request(%{state | requests: requests}, request_id, response, status)
        {:reply, :ok, state}

      {rpc_id, requests} ->
        decision = response["decision"] || "decline"
        # Codex has no "always"; the closest is for the rest of the session.
        codex_decision = if decision == "acceptAlways", do: "acceptForSession", else: decision
        Connection.respond(state.conn, rpc_id, {:ok, %{"decision" => codex_decision}})
        state = resolve_request(%{state | requests: requests}, request_id, decision)
        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_info({:json_rpc, _conn, {:notification, method, params}}, state),
    do: {:noreply, notification(method, params || %{}, state)}

  def handle_info({:json_rpc, _conn, {:request, id, method, params}}, %{turn: turn} = state)
      when turn != nil and
             method in [
               "item/commandExecution/requestApproval",
               "item/fileChange/requestApproval",
               "item/permissions/requestApproval"
             ] do
    {kind, prompt} =
      case method do
        "item/commandExecution/requestApproval" ->
          {"command", params["reason"] || params["command"]}

        "item/fileChange/requestApproval" ->
          {"file-change", params["reason"]}

        _ ->
          {"permission", params["reason"]}
      end

    native = params["approvalId"] || params["itemId"] || "request-#{id}"
    {state, request_id} = open_request(flush(state), native, kind, prompt)
    {:noreply, %{state | requests: Map.put(state.requests, request_id, id)}}
  end

  def handle_info(
        {:json_rpc, _conn, {:request, id, "item/tool/requestUserInput", params}},
        %{turn: turn} = state
      )
      when turn != nil do
    questions =
      (params["questions"] || [])
      |> Enum.with_index(1)
      |> Enum.map(fn {question, index} ->
        %{
          "id" => text(question["id"], "question-#{index}"),
          "header" => text(question["header"], "Question"),
          "question" => text(question["question"], "Choose an answer."),
          "options" =>
            for {option, n} <- Enum.with_index(question["options"] || [], 1) do
              label = text(option["label"], "Option #{n}")
              %{"label" => label, "description" => text(option["description"], label)}
            end
        }
      end)

    native = params["itemId"] || "request-#{id}"
    {state, request_id} = open_question(flush(state), native, questions)
    ids = Enum.map(questions, & &1["id"])
    {:noreply, %{state | requests: Map.put(state.requests, request_id, {:question, id, ids})}}
  end

  # Other requests are not wired up yet; refuse rather than hang the turn.
  def handle_info({:json_rpc, conn, {:request, id, method, _params}}, state) do
    Connection.respond(
      conn,
      id,
      {:error, %{"code" => -32601, "message" => "#{method} is not supported"}}
    )

    {:noreply, state}
  end

  def handle_info(:flush, state), do: {:noreply, flush(%{state | flush_timer: nil}, :timer)}
  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def code_change(_old, state, _extra), do: {:ok, %{state | v: @state_version}}

  # The message, with where its files are, and its images inline.
  defp codex_input(turn) do
    attachments = Map.get(turn, :attachments, [])
    text = T3.Attachments.prompt_text(turn.text, attachments)

    if(text == "", do: [], else: [%{"type" => "text", "text" => text}]) ++
      for {mime, data} <- T3.Attachments.native_images(attachments),
          do: %{"type" => "image", "url" => "data:#{mime};base64,#{data}"}
  end

  defp non_empty(value, default) when is_binary(value),
    do: if(String.trim(value) == "", do: default, else: String.trim(value))

  defp non_empty(_value, default), do: default

  # Codex takes each answered question's choices as strings.
  defp codex_answers(answers, question_ids) do
    for {id, value} <- answers, id in question_ids, into: %{} do
      values = if is_list(value), do: value, else: [value]
      {id, %{"answers" => for(v <- values, v != nil, do: to_string(v))}}
    end
  end

  defp text(value, default) when is_binary(value) do
    if String.trim(value) == "", do: default, else: String.trim(value)
  end

  defp text(_value, default), do: default

  # --- turn lifecycle -------------------------------------------------------------

  defp begin_turn(state, turn) do
    with {:ok, state} <- connect(state, turn),
         {:ok, state} <- ensure_native_thread(state, turn),
         {:ok, native_turn} <- start_native_turn(state, turn) do
      at = Entities.now()
      ids = Map.put(turn.ids, :provider_turn, "provider-turn:codex:#{native_turn}")
      turn = %{turn | ids: ids} |> Map.put(:native_turn_id, native_turn)

      commit(state, fn stream ->
        [
          Orchestration.create(
            "provider-turn",
            ids.provider_turn,
            Entities.provider_turn(ids, native_turn, turn.run_ordinal, at)
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
            &Map.merge(&1, %{
              "status" => "active",
              "nativeThreadRef" => Entities.provider_ref(state.native_thread_id),
              "updatedAt" => at
            })
          ),
          Orchestration.upsert(
            stream,
            "thread",
            ids.thread,
            &Map.put(&1, "activeProviderThreadId", ids.provider_thread)
          )
        ]
      end)

      {:ok, %{state | turn: turn}}
    end
  end

  # Paginated threads (current Codex) cut history before a turn; legacy threads
  # only take a count of turns to drop.
  defp rewind(state, plan) do
    thread = state.native_thread_id

    with {:error, _} <-
           if(plan.first_dropped,
             do:
               Connection.call(state.conn, "thread/revert", %{
                 "threadId" => thread,
                 "beforeTurnId" => plan.first_dropped
               }),
             else: {:error, :no_turn_id}
           ),
         do:
           Connection.call(state.conn, "thread/rollback", %{
             "threadId" => thread,
             "numTurns" => plan.drop
           })
  end

  defp rpc_message(%{"message" => message}) when is_binary(message), do: message
  defp rpc_message(reason), do: inspect(reason)

  defp connect(%{conn: nil} = state, turn) do
    cmd = Application.get_env(:t3, :codex_command, ["codex", "app-server"])

    with {:ok, conn} <- Connection.start_link(cmd: cmd, handler: self(), cd: turn.cwd),
         {:ok, _} <-
           Connection.call(conn, "initialize", %{
             "clientInfo" => %{
               "name" => "t3code_elixir",
               "title" => "T3 Code",
               "version" => "0.1.0"
             },
             "capabilities" => %{
               "experimentalApi" => true,
               "optOutNotificationMethods" => ["turn/diff/updated"]
             }
           }) do
      Connection.notify(conn, "initialized", nil)
      {:ok, %{state | conn: conn}}
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp connect(state, _turn), do: {:ok, state}

  defp ensure_native_thread(%{native_thread_id: id} = state, _turn) when is_binary(id),
    do: {:ok, state}

  # A fork's first turn starts from a copy of the source thread, cut after its turn.
  defp ensure_native_thread(state, %{fork: %{thread: source, turn: last}} = turn) do
    params =
      thread_params(state, turn)
      |> Map.merge(%{"threadId" => source, "lastTurnId" => last})

    case Connection.call(state.conn, "thread/fork", params) do
      {:ok, %{"thread" => %{"id" => id}}} -> {:ok, %{state | native_thread_id: id}}
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp ensure_native_thread(state, turn) do
    params = thread_params(state, turn)

    result =
      if turn.native_thread_id,
        do:
          Connection.call(
            state.conn,
            "thread/resume",
            Map.merge(params, %{"threadId" => turn.native_thread_id, "excludeTurns" => true})
          ),
        else: Connection.call(state.conn, "thread/start", params)

    case result do
      {:ok, %{"thread" => %{"id" => id}}} -> {:ok, %{state | native_thread_id: id}}
      {:error, reason} -> {:error, reason, state}
    end
  end

  # The thread's settings, with T3's own MCP server for the agent when allowed.
  defp thread_params(state, turn) do
    params = %{"cwd" => turn.cwd, "model" => turn.model}

    case mcp(state, turn) do
      nil ->
        params

      mcp ->
        Map.put(params, "config", %{
          "mcp_servers" => %{
            "t3-code" => %{
              "url" => mcp.url,
              "http_headers" => %{"Authorization" => mcp.authorization}
            }
          }
        })
    end
  end

  defp mcp(state, turn), do: T3.Mcp.for_agent(state.thread_id, Entities.instance(turn.ids))

  defp start_native_turn(state, turn) do
    {approval, sandbox} =
      Map.get(@runtime_policies, turn.runtime_mode, @runtime_policies["full-access"])

    params = %{
      "threadId" => state.native_thread_id,
      "input" => codex_input(turn),
      "cwd" => turn.cwd,
      "model" => turn.model,
      "approvalPolicy" => approval,
      "approvalsReviewer" => "user",
      "sandboxPolicy" => %{"type" => sandbox},
      "summary" => "detailed",
      # Always explicit: Codex keeps the last collaboration mode on a resumed thread.
      "collaborationMode" => %{
        "mode" => if(Map.get(turn, :interaction_mode) == "plan", do: "plan", else: "default"),
        "settings" =>
          if(mcp(state, turn),
            do: %{"model" => turn.model, "developer_instructions" => T3.Mcp.instructions()},
            else: %{"model" => turn.model}
          )
      }
    }

    case Connection.call(state.conn, "turn/start", params) do
      {:ok, %{"turn" => %{"id" => id}}} -> {:ok, id}
      {:error, reason} -> {:error, reason, state}
    end
  end

  # --- notifications ----------------------------------------------------------

  # Quota comes alongside token usage, mostly unchanged; it merges onto the provider entry.
  defp notification("account/rateLimits/updated", %{"rateLimits" => snapshot}, state) do
    T3.ProviderUsageLimits.update("codex", T3.ProviderUsageLimits.Codex.windows(snapshot))
    state
  end

  defp notification(_method, _params, %{turn: nil} = state), do: state

  defp notification(
         "item/started",
         %{"item" => %{"type" => "agentMessage", "id" => native}},
         state
       ),
       do: ensure_item(state, native, :assistant)

  defp notification("item/started", %{"item" => %{"type" => "commandExecution"} = item}, state) do
    state
    |> ensure_item(item["id"], :command, %{"input" => item["command"] || "", "output" => ""})
  end

  # Plan mode's proposed plan streams as its own item.
  defp notification("item/started", %{"item" => %{"type" => "plan", "id" => native}}, state),
    do: ensure_item(state, native, :plan)

  defp notification("item/plan/delta", %{"itemId" => native, "delta" => delta}, state),
    do: state |> ensure_item(native, :plan) |> buffer(native, "markdown", delta)

  # The agent's own todo list for the turn.
  defp notification("turn/plan/updated", %{"plan" => plan} = params, state) when is_list(plan) do
    steps =
      for {step, index} <- Enum.with_index(plan, 1) do
        %{
          "id" => "step-#{index}",
          "text" => non_empty(step["step"], "Step #{index}"),
          "status" =>
            case step["status"] do
              "completed" -> "completed"
              "inProgress" -> "running"
              _ -> "pending"
            end
        }
      end

    explanation =
      if is_binary(params["explanation"]) and params["explanation"] != "",
        do: params["explanation"]

    write_todo(state, "turn-plan:#{params["turnId"]}", steps, explanation)
  end

  defp notification("item/agentMessage/delta", %{"itemId" => native, "delta" => delta}, state),
    do: state |> ensure_item(native, :assistant) |> buffer(native, "text", delta)

  defp notification("item/reasoning/" <> _, %{"itemId" => native, "delta" => delta}, state),
    do: state |> ensure_item(native, :reasoning) |> buffer(native, "text", delta)

  defp notification(
         "item/commandExecution/outputDelta",
         %{"itemId" => native, "delta" => delta},
         state
       ),
       do:
         state
         |> ensure_item(native, :command, %{"input" => "", "output" => ""})
         |> buffer(native, "output", delta)

  defp notification("item/completed", %{"item" => item}, state),
    do: complete_item(flush(state), item)

  defp notification("error", %{"error" => error} = params, state) do
    if params["willRetry"] == true,
      do: state,
      else: %{state | failure: error["message"] || "Codex reported an error"}
  end

  defp notification("turn/completed", %{"turn" => turn}, state) do
    state = flush(state)

    status =
      if turn["status"] in ["completed", "interrupted", "failed"],
        do: turn["status"],
        else: "failed"

    state =
      Enum.reduce(Map.keys(state.requests), state, &resolve_request(&2, &1, nil, "cancelled"))

    finish(state, status, state.failure || get_in(turn, ["error", "message"]))
    %{state | turn: nil, items: %{}, requests: %{}}
  end

  defp notification(_method, _params, state), do: state

  defp complete_item(state, %{"type" => "agentMessage", "id" => native} = item) do
    finish_item(state, native, "completed", fn entity ->
      Map.merge(entity, %{"text" => item["text"] || entity["text"], "streaming" => false})
    end)
  end

  # The completed plan item is authoritative over its streamed deltas.
  defp complete_item(state, %{"type" => "plan", "id" => native} = item) do
    text = if is_binary(item["text"]) and item["text"] != "", do: item["text"]
    state |> ensure_item(native, :plan) |> finish_plan(native, text)
  end

  defp complete_item(state, %{"type" => "reasoning", "id" => native}) do
    if Map.has_key?(state.items, native),
      do: finish_item(state, native, "completed", &Map.put(&1, "streaming", false)),
      else: state
  end

  defp complete_item(state, %{"type" => "commandExecution", "id" => native} = item) do
    status =
      case item["status"] do
        "failed" -> "failed"
        "declined" -> "cancelled"
        _ -> "completed"
      end

    state
    |> ensure_item(native, :command, %{"input" => item["command"] || "", "output" => ""})
    |> finish_item(native, status, fn entity ->
      entity
      |> Map.put("output", item["aggregatedOutput"] || entity["output"] || "")
      |> then(
        &if(is_integer(item["exitCode"]), do: Map.put(&1, "exitCode", item["exitCode"]), else: &1)
      )
    end)
  end

  defp complete_item(state, %{"type" => "fileChange", "id" => native, "changes" => [change | _]}) do
    ids = state.turn.ids
    at = Entities.now()
    item_id = item_id(ids, native)

    commit(state, fn stream ->
      [
        Orchestration.create(
          "turn-item",
          item_id,
          Entities.turn_item(
            ids,
            item_id,
            "file_change",
            Orchestration.next_ordinal(stream),
            "completed",
            at,
            %{
              "fileName" => change["path"] || "file",
              "diffStr" => change["diff"] || ""
            }
          )
        )
      ]
    end)

    state
  end

  defp complete_item(state, _item), do: state
end
