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

  @state_version 3

  # runtimeMode -> the CLI's permission mode; prompts it raises become approval
  # requests the user answers in the client.
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

  @doc "Adds a message to the running turn of `run_id`; Claude takes it at once."
  @spec steer(String.t(), String.t(), String.t()) :: :ok | {:error, String.t()}
  def steer(thread_id, run_id, text) do
    case Registry.lookup(T3.Claude.Registry, thread_id) do
      [{pid, _}] -> GenServer.call(pid, {:steer, run_id, text})
      [] -> {:error, "no running turn"}
    end
  end

  @doc """
  Answers a prompt: a permission's `%{"decision" => ProviderApprovalDecision}`,
  AskUserQuestion's `%{"answers" => answers}`, or `%{"dismissed" => true}`.
  """
  @spec respond(String.t(), String.t(), map) :: :ok | {:error, String.t()}
  def respond(thread_id, request_id, response) do
    case Registry.lookup(T3.Claude.Registry, thread_id) do
      [{pid, _}] -> GenServer.call(pid, {:respond, request_id, response})
      [] -> {:error, "no pending request"}
    end
  end

  @doc """
  Rewinds the conversation: drops the live session, so the next turn resumes the
  recorded session at the new head (`nativeConversationHeadRef`), or starts a new
  one when the rollback goes back to the thread's start.
  """
  @spec rollback(String.t(), map) :: {:ok, map} | {:error, String.t()}
  def rollback(thread_id, %{head: head}) do
    reply =
      case Registry.lookup(T3.Claude.Registry, thread_id) do
        [{pid, _}] -> GenServer.call(pid, :rollback, 30_000)
        [] -> :ok
      end

    with :ok <- reply do
      {:ok,
       if(head,
         do: %{"nativeConversationHeadRef" => Entities.provider_ref(head, "claudeAgent")},
         else: %{"nativeThreadRef" => nil, "nativeConversationHeadRef" => nil}
       )}
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
       interrupted: false,
       # Open permission prompts: request id -> the CLI's control request id.
       requests: %{},
       # The session's permission mode, switched before a turn that needs another.
       permission_mode: nil,
       # A steer ends the turn's current part with an "aborted" result; that one
       # result is not the end of the turn.
       steered: false
     }}
  end

  @impl true
  def handle_call({:start_turn, turn}, _from, state) do
    ids = Map.put(turn.ids, :provider_turn, "provider-turn:claudeAgent:#{turn.ids.run}")
    turn = %{turn | ids: ids}
    state = %{state | turn: turn, items: %{}, blocks: %{}, interrupted: false}

    case ensure_session(state, turn) do
      {:ok, state} ->
        Session.send_message(state.session, claude_content(turn))
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

  def handle_call({:steer, run_id, text}, _from, %{turn: %{ids: %{run: run_id}}} = state)
      when state.session != nil do
    Session.send_message(state.session, text, priority: "now")
    {:reply, :ok, %{state | steered: true}}
  end

  def handle_call(:rollback, _from, %{turn: nil} = state) do
    if state.session, do: GenServer.stop(state.session)
    {:reply, :ok, %{state | session: nil, session_id: nil, permission_mode: nil}}
  end

  def handle_call(:rollback, _from, state),
    do: {:reply, {:error, "Interrupt the current turn before rewinding."}, state}

  def handle_call({:steer, _run_id, _text}, _from, state),
    do: {:reply, {:error, "no running turn"}, state}

  def handle_call({:respond, request_id, response}, _from, state) do
    case Map.pop(state.requests, request_id) do
      {nil, _} ->
        {:reply, {:error, "no pending request #{request_id}"}, state}

      # The answers go back as the tool's input, keyed by question text.
      {{:question, control_id, input}, requests} ->
        {answer, status} =
          if response["dismissed"],
            do: {{:deny, "The user dismissed the question."}, "cancelled"},
            else:
              {{:allow, Map.put(input, "answers", claude_answers(response["answers"]))},
               "resolved"}

        Session.answer_permission(state.session, control_id, answer)
        state = resolve_request(%{state | requests: requests}, request_id, response, status)
        {:reply, :ok, state}

      {control_id, requests} ->
        decision = response["decision"] || "decline"

        answer =
          if decision in ["accept", "acceptForSession", "acceptAlways"],
            do: :allow,
            else: {:deny, "The user declined."}

        Session.answer_permission(state.session, control_id, answer)
        state = resolve_request(%{state | requests: requests}, request_id, decision)
        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_info({:claude, _session, {:message, message}}, state),
    do: {:noreply, message(message, state)}

  def handle_info(
        {:claude, session, {:permission, id, _tool, _input, _context}},
        %{turn: nil} = state
      ) do
    Session.answer_permission(session, id, {:deny, "No turn is running."})
    {:noreply, state}
  end

  # Plan mode's plan: captured for the user, and Claude stops to wait for them.
  def handle_info({:claude, session, {:permission, id, "ExitPlanMode", input, _}}, state) do
    state =
      state
      |> flush()
      |> ensure_item("plan:#{id}", :plan)
      |> finish_plan("plan:#{id}", input["plan"] || "")

    Session.answer_permission(
      session,
      id,
      {:deny,
       "The client captured your proposed plan. Stop here and wait for the user's feedback or implementation request in a later turn."}
    )

    {:noreply, state}
  end

  def handle_info({:claude, _session, {:permission, id, "AskUserQuestion", input, _}}, state) do
    {state, request_id} = open_question(flush(state), id, claude_questions(input))
    request = {:question, id, input}
    {:noreply, %{state | requests: Map.put(state.requests, request_id, request)}}
  end

  def handle_info({:claude, _session, {:permission, id, tool, input, _context}}, state) do
    {kind, prompt} =
      cond do
        tool == "Bash" -> {"command", input["command"]}
        tool in @file_tools -> {"file-change", input["file_path"]}
        tool in ["Read", "Glob", "Grep"] -> {"file-read", input["file_path"] || input["pattern"]}
        true -> {"permission", tool}
      end

    {state, request_id} = open_request(flush(state), id, kind, prompt)
    {:noreply, %{state | requests: Map.put(state.requests, request_id, id)}}
  end

  def handle_info({:EXIT, session, _reason}, %{session: session} = state) do
    state = if state.turn, do: end_turn(state, "failed", "Claude exited"), else: state
    {:noreply, %{state | session: nil}}
  end

  def handle_info(:flush, state), do: {:noreply, flush(%{state | flush_timer: nil})}
  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def code_change(_old, state, _extra),
    do:
      {:ok,
       state
       |> Map.put_new(:permission_mode, nil)
       |> Map.put_new(:steered, false)
       |> Map.put(:v, @state_version)}

  # AskUserQuestion's questions; each is keyed by its text, as Claude keys answers.
  defp claude_questions(input) do
    for {question, index} <- Enum.with_index(input["questions"] || [], 1),
        text = String.trim(question["question"] || ""),
        text != "" do
      %{
        "id" => text,
        "header" => non_empty(question["header"], "Question #{index}"),
        "question" => text,
        "options" =>
          for option <- question["options"] || [],
              label = String.trim(option["label"] || ""),
              label != "" do
            %{"label" => label, "description" => non_empty(option["description"], label)}
          end,
        "multiSelect" => question["multiSelect"] == true
      }
    end
  end

  defp claude_answers(answers) do
    for {question, value} <- answers || %{}, into: %{} do
      {question, if(is_list(value), do: Enum.join(value, ", "), else: to_string(value || ""))}
    end
  end

  defp non_empty(value, default) when is_binary(value),
    do: if(String.trim(value) == "", do: default, else: String.trim(value))

  defp non_empty(_value, default), do: default

  # The message, with where its files are; images go inline as content blocks.
  defp claude_content(turn) do
    attachments = Map.get(turn, :attachments, [])
    text = T3.Attachments.prompt_text(turn.text, attachments)

    case T3.Attachments.native_images(attachments) do
      [] ->
        text

      images ->
        [%{"type" => "text", "text" => text}] ++
          for {mime, data} <- images,
              do: %{
                "type" => "image",
                "source" => %{"type" => "base64", "media_type" => mime, "data" => data}
              }
    end
  end

  # Plan mode, or the thread's runtime mode.
  defp permission_mode(turn) do
    if Map.get(turn, :interaction_mode) == "plan",
      do: "plan",
      else: Map.get(@permission_modes, turn.runtime_mode, "default")
  end

  defp ensure_session(%{session: session} = state, turn) when session != nil do
    mode = permission_mode(turn)

    if state.permission_mode != mode do
      _ = Session.control(session, "set_permission_mode", %{"mode" => mode})
    end

    {:ok, %{state | permission_mode: mode}}
  end

  defp ensure_session(state, turn) do
    Process.flag(:trap_exit, true)

    opts = [
      handler: self(),
      cd: turn.cwd,
      model: turn.model,
      permission_mode: permission_mode(turn),
      resume: turn.native_thread_id,
      resume_at: Map.get(turn, :head),
      partial_messages: true
    ]

    opts =
      case Application.get_env(:t3, :claude_command) do
        nil -> opts
        command -> Keyword.put(opts, :command, command)
      end

    case Session.start_link(opts) do
      {:ok, session} -> {:ok, %{state | session: session, permission_mode: permission_mode(turn)}}
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

  defp message(
         %{"type" => "assistant", "message" => %{"id" => id, "content" => content}} = message,
         state
       ) do
    # The last assistant message is where a rollback to this turn resumes.
    state = if message["uuid"], do: put_in(state.turn[:head], message["uuid"]), else: state

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

  # The part of a steered turn that the new message cut short; the turn goes on.
  defp message(%{"type" => "result", "terminal_reason" => reason}, %{steered: true} = state)
       when reason in ["aborted_streaming", "aborted_tools"] and not state.interrupted,
       do: %{state | steered: false}

  defp message(%{"type" => "result"} = result, state) do
    state = %{state | steered: false}

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

  # Claude's todo list: one per run, updated in place.
  defp assistant_block(%{"type" => "tool_use", "name" => "TodoWrite"} = block, _id, _index, state) do
    steps =
      for {todo, index} <- Enum.with_index(get_in(block, ["input", "todos"]) || [], 1),
          text = non_empty(todo["content"], ""),
          text != "" do
        status =
          case todo["status"] do
            "completed" -> "completed"
            "in_progress" -> "running"
            _ -> "pending"
          end

        %{"id" => "step-#{index}", "text" => text, "status" => status}
      end

    write_todo(state, "todos:#{state.turn.ids.run}", steps)
  end

  # Shown as their question card and plan instead.
  defp assistant_block(%{"type" => "tool_use", "name" => name}, _id, _index, state)
       when name in ["AskUserQuestion", "ExitPlanMode"],
       do: state

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

    # Items and prompts still open when the turn ends are closed with it.
    state = close_open_items(state, status)

    state =
      Enum.reduce(Map.keys(state.requests), state, &resolve_request(&2, &1, nil, "cancelled"))

    if head = state.turn[:head] do
      commit(state, fn stream ->
        [
          Orchestration.upsert(
            stream,
            "provider-turn",
            state.turn.ids.provider_turn,
            &Map.put(&1, "nativeTurnRef", Entities.provider_ref(head, "claudeAgent"))
          )
        ]
      end)
    end

    finish(state, status, failure)
    %{state | turn: nil, items: %{}, blocks: %{}, requests: %{}}
  end

  defp block_key(message_id, index), do: "#{message_id}:#{index}"

  defp result_text(content) when is_binary(content), do: content

  defp result_text(content) when is_list(content),
    do: Enum.map_join(content, "", fn block -> block["text"] || "" end)

  defp result_text(_), do: ""
end
