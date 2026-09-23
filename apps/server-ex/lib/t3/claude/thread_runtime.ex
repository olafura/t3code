defmodule T3.Claude.ThreadRuntime do
  @moduledoc """
  Runs one thread's Claude turns through the `claude` CLI (`T3.Claude.Session`) and
  writes them into the thread's log.

  One CLI process serves every turn of the thread: each message is another user
  message on its stream-json input. If the process has gone, the next turn starts
  a new one with `--resume` on the recorded session id. Text and thinking stream
  from partial messages and are written as appends; tool calls become command,
  file-change, web-search, or generic tool items, finished by their tool results.
  """

  use GenServer, restart: :temporary

  require Logger

  import T3.Orchestration.TurnWriter

  alias T3.Claude.Session
  alias T3.Orchestration
  alias T3.Orchestration.Entities

  @state_version 1

  # runtimeMode -> the CLI's permission mode. Prompts are not answered yet, so
  # modes that would ask are declined in `handle_info/2`.
  @permission_modes %{
    "full-access" => "bypassPermissions",
    "auto-accept-edits" => "acceptEdits",
    "auto" => "acceptEdits",
    "approval-required" => "default"
  }

  @file_tools ~w(Edit Write MultiEdit NotebookEdit)
  @web_tools ~w(WebSearch WebFetch)

  def driver, do: "claudeAgent"

  @spec start_turn(String.t(), map) :: :ok
  def start_turn(thread_id, turn),
    do: thread_id |> ensure() |> GenServer.call({:start_turn, turn}, 60_000)

  @spec interrupt(String.t(), String.t() | nil) :: :ok | {:error, String.t()}
  def interrupt(thread_id, _run_id) do
    case Registry.lookup(T3.Claude.Registry, thread_id) do
      [{pid, _}] -> GenServer.call(pid, :interrupt, 15_000)
      [] -> {:error, "no active Claude turn in this thread"}
    end
  end

  def start_link(thread_id),
    do:
      GenServer.start_link(__MODULE__, thread_id,
        name: {:via, Registry, {T3.Claude.Registry, thread_id}}
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
       session: nil,
       session_id: nil,
       turn: nil,
       items: %{},
       buffer: %{},
       flush_timer: nil,
       # Streamed content blocks of the message in flight: index -> native item key.
       blocks: %{},
       message_id: nil,
       interrupted: false
     }}
  end

  @impl true
  def handle_call({:start_turn, turn}, _from, state) do
    ids = Map.put(turn.ids, :provider_turn, "provider-turn:claudeAgent:#{turn.ids.run}")
    turn = %{turn | ids: ids}
    state = %{state | turn: turn, items: %{}, blocks: %{}, interrupted: false}

    case ensure_session(state, turn) do
      {:ok, state} ->
        Session.send_message(state.session, turn.text)
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

        {:reply, :ok, state}

      {:error, reason} ->
        Logger.warning("claude turn failed to start: #{inspect(reason)}")
        finish(state, "failed", "Claude could not start: #{inspect(reason)}")
        {:reply, :ok, %{state | turn: nil}}
    end
  end

  def handle_call(:interrupt, _from, %{turn: turn, session: session} = state)
      when turn != nil and session != nil do
    Session.control(session, "interrupt")
    {:reply, :ok, %{state | interrupted: true}}
  end

  def handle_call(:interrupt, _from, state), do: {:reply, {:error, "no running turn"}, state}

  @impl true
  def handle_info({:claude, _session, {:message, message}}, state),
    do: {:noreply, message(message, state)}

  def handle_info({:claude, session, {:permission, id, tool, _input, _context}}, state) do
    Session.answer_permission(
      session,
      id,
      {:deny, "#{tool} needs approval, which this node cannot ask for yet."}
    )

    {:noreply, state}
  end

  def handle_info({:EXIT, session, _reason}, %{session: session} = state) do
    state = if state.turn, do: end_turn(state, "failed", "Claude exited"), else: state
    {:noreply, %{state | session: nil}}
  end

  def handle_info(:flush, state), do: {:noreply, flush(%{state | flush_timer: nil})}
  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def code_change(_old, state, _extra), do: {:ok, %{state | v: @state_version}}

  defp ensure_session(%{session: session} = state, _turn) when session != nil, do: {:ok, state}

  defp ensure_session(state, turn) do
    Process.flag(:trap_exit, true)

    opts = [
      handler: self(),
      cd: turn.cwd,
      model: turn.model,
      permission_mode: Map.get(@permission_modes, turn.runtime_mode, "default"),
      resume: turn.native_thread_id,
      partial_messages: true
    ]

    opts =
      case Application.get_env(:t3, :claude_command) do
        nil -> opts
        command -> Keyword.put(opts, :command, command)
      end

    case Session.start_link(opts) do
      {:ok, session} -> {:ok, %{state | session: session}}
      {:error, reason} -> {:error, reason}
    end
  end

  # --- messages ------------------------------------------------------------------

  defp message(_message, %{turn: nil} = state), do: state

  defp message(%{"type" => "system", "subtype" => "init", "session_id" => session_id}, state) do
    ids = state.turn.ids

    if session_id != state.session_id do
      commit(state, fn stream ->
        [
          Orchestration.upsert(
            stream,
            "provider-thread",
            ids.provider_thread,
            &Map.put(&1, "nativeThreadRef", Entities.provider_ref(session_id, "claudeAgent"))
          )
        ]
      end)
    end

    %{state | session_id: session_id}
  end

  defp message(%{"type" => "stream_event", "event" => event}, state),
    do: stream_event(event, state)

  defp message(%{"type" => "assistant", "message" => %{"id" => id, "content" => content}}, state) do
    content
    |> Enum.with_index()
    |> Enum.reduce(flush(state), fn {block, index}, state ->
      assistant_block(block, id, index, state)
    end)
    |> Map.put(:blocks, %{})
  end

  defp message(%{"type" => "user", "message" => %{"content" => content}}, state)
       when is_list(content) do
    Enum.reduce(content, state, fn
      %{"type" => "tool_result", "tool_use_id" => tool_id} = result, state ->
        tool_result(state, tool_id, result)

      _, state ->
        state
    end)
  end

  defp message(%{"type" => "result"} = result, state) do
    status =
      cond do
        state.interrupted -> "interrupted"
        result["is_error"] == true or result["subtype"] != "success" -> "failed"
        true -> "completed"
      end

    failure = if status == "failed", do: result["result"] || result["subtype"]
    end_turn(state, status, failure)
  end

  defp message(_message, state), do: state

  # Partial messages: text and thinking stream into their items as they arrive.
  defp stream_event(%{"type" => "message_start", "message" => %{"id" => id}}, state),
    do: %{state | message_id: id, blocks: %{}}

  defp stream_event(
         %{
           "type" => "content_block_start",
           "index" => index,
           "content_block" => %{"type" => type}
         },
         state
       )
       when type in ["text", "thinking"] do
    key = block_key(state.message_id, index)
    kind = if type == "text", do: :assistant, else: :reasoning
    state |> ensure_item(key, kind) |> put_in([:blocks, index], key)
  end

  defp stream_event(%{"type" => "content_block_delta", "index" => index, "delta" => delta}, state) do
    text = delta["text"] || delta["thinking"]

    case {state.blocks[index], text} do
      {nil, _} -> state
      {_, nil} -> state
      {key, text} -> buffer(state, key, "text", text)
    end
  end

  defp stream_event(_event, state), do: state

  # A complete assistant message: finishes streamed blocks with their final text,
  # and creates items for blocks that did not stream (tool calls, unstreamed text).
  defp assistant_block(%{"type" => "text", "text" => text}, id, index, state) do
    key = block_key(id, index)

    state
    |> ensure_item(key, :assistant)
    |> finish_item(key, "completed", &Map.merge(&1, %{"text" => text, "streaming" => false}))
  end

  defp assistant_block(%{"type" => "thinking", "thinking" => text}, id, index, state) do
    key = block_key(id, index)

    state
    |> ensure_item(key, :reasoning)
    |> finish_item(key, "completed", &Map.merge(&1, %{"text" => text, "streaming" => false}))
  end

  defp assistant_block(
         %{"type" => "tool_use", "id" => tool_id, "name" => name} = block,
         _id,
         _index,
         state
       ) do
    input = block["input"] || %{}

    {kind, fields} =
      cond do
        name == "Bash" ->
          {:command, %{"input" => input["command"] || "", "output" => ""}}

        name in @file_tools ->
          {:file, %{"fileName" => input["file_path"] || input["notebook_path"] || name}}

        name in @web_tools ->
          {:web, %{"patterns" => Enum.filter([input["query"], input["url"]], &is_binary/1)}}

        true ->
          {:tool, %{"toolName" => name, "input" => input}}
      end

    ensure_item(state, tool_id, kind, fields)
  end

  defp assistant_block(_block, _id, _index, state), do: state

  defp tool_result(state, tool_id, result) do
    case state.items[tool_id] do
      nil ->
        state

      %{kind: kind} ->
        status = if result["is_error"] == true, do: "failed", else: "completed"
        output = result_text(result["content"])

        finish_item(state, tool_id, status, fn entity ->
          case kind do
            :command -> Map.put(entity, "output", output)
            :file -> Map.put(entity, "diffStr", output)
            :tool -> Map.put(entity, "output", output)
            _ -> entity
          end
        end)
    end
  end

  defp end_turn(state, status, failure) do
    state = flush(state)

    # Items still open when the turn ends are closed with it.
    state = close_open_items(state, status)

    finish(state, status, failure)
    %{state | turn: nil, items: %{}, blocks: %{}}
  end

  defp block_key(message_id, index), do: "#{message_id}:#{index}"

  defp result_text(content) when is_binary(content), do: content

  defp result_text(content) when is_list(content),
    do: Enum.map_join(content, "", fn block -> block["text"] || "" end)

  defp result_text(_), do: ""
end
