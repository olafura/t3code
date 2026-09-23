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
       failure: nil
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

  @impl true
  def handle_info({:json_rpc, _conn, {:notification, method, params}}, state),
    do: {:noreply, notification(method, params || %{}, state)}

  # Approvals and questions are not wired up yet; decline rather than hang the turn.
  def handle_info({:json_rpc, conn, {:request, id, method, _params}}, state) do
    Connection.respond(
      conn,
      id,
      {:error, %{"code" => -32601, "message" => "#{method} is not supported"}}
    )

    {:noreply, state}
  end

  def handle_info(:flush, state), do: {:noreply, flush(%{state | flush_timer: nil})}
  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def code_change(_old, state, _extra), do: {:ok, %{state | v: @state_version}}

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

  defp ensure_native_thread(state, turn) do
    params = %{"cwd" => turn.cwd, "model" => turn.model}

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

  defp start_native_turn(state, turn) do
    {approval, sandbox} =
      Map.get(@runtime_policies, turn.runtime_mode, @runtime_policies["full-access"])

    params = %{
      "threadId" => state.native_thread_id,
      "input" => [%{"type" => "text", "text" => turn.text}],
      "cwd" => turn.cwd,
      "model" => turn.model,
      "approvalPolicy" => approval,
      "approvalsReviewer" => "user",
      "sandboxPolicy" => %{"type" => sandbox},
      "summary" => "detailed"
    }

    case Connection.call(state.conn, "turn/start", params) do
      {:ok, %{"turn" => %{"id" => id}}} -> {:ok, id}
      {:error, reason} -> {:error, reason, state}
    end
  end

  # --- notifications ----------------------------------------------------------

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

    finish(state, status, state.failure || get_in(turn, ["error", "message"]))
    %{state | turn: nil, items: %{}}
  end

  defp notification(_method, _params, state), do: state

  defp complete_item(state, %{"type" => "agentMessage", "id" => native} = item) do
    finish_item(state, native, "completed", fn entity ->
      Map.merge(entity, %{"text" => item["text"] || entity["text"], "streaming" => false})
    end)
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
