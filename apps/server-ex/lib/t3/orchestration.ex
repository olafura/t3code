defmodule T3.Orchestration do
  @moduledoc """
  Client commands on this node's threads: start a thread, send a message, answer
  an approval, and interrupt a run, for threads whose provider is Codex, Claude, or an
  ACP agent such as OpenCode;
  plus the diffs of their checkpoints.

  A message sent while a run is active is queued: its run waits as `queued` with a
  queue position and starts when the thread is next idle (`start_next/1`). Nodes do
  not steer a running turn; "restart" interrupts it and puts the message first.

  Each command is decided inside the thread's stream process (`T3.Streams.transact/3`),
  so reading the thread and writing its new entities is atomic. Starting the provider
  turn happens after the commit, in the provider's runtime (`T3.Codex.ThreadRuntime`,
  `T3.Claude.ThreadRuntime`), which streams the turn back into the same log.
  """

  alias T3.Orchestration.Entities
  alias T3.{Patch, StreamState}

  @active_statuses ~w(preparing starting running waiting)

  @thread_updates ~w(thread.archive thread.unarchive thread.delete thread.settle thread.unsettle
                     thread.snooze thread.unsnooze thread.pin thread.unpin thread.pin.reorder
                     thread.active.reorder thread.visit thread.mark-unread thread.metadata.update
                     thread.runtime-mode.set thread.interaction-mode.set thread.model-selection.set
                     provider.switch thread.pull-request.link thread.pull-request.unlink)

  @doc "Handles one client RPC by method name; see `packages/contracts/src/orchestrationV2.ts`."
  @spec handle(String.t(), map) :: {:ok, term} | {:error, String.t()}
  def handle("orchestration.dispatchCommand", command), do: dispatch(command)
  def handle("orchestration.launchThread", input), do: launch_thread(input)
  def handle("orchestration.searchThreads", input), do: T3.Search.threads(input)

  # This node's archived threads, with the projects they belong to.
  def handle("orchestration.getArchivedShellSnapshot", _input) do
    rows = for {{node, _id}, row} <- T3.Shell.rows(), node == node(), do: row

    {:ok,
     %{
       "schemaVersion" => 1,
       "snapshotSequence" => 0,
       "projects" => for({"project", row} <- rows, row["deletedAt"] == nil, do: row),
       "threads" =>
         for(
           {"thread", row} <- rows,
           row["deletedAt"] == nil and row["archivedAt"] != nil,
           do: row
         )
     }}
  end

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
    # Uploads join the thread before the message names them.
    case T3.Attachments.claim(thread_id, command["attachments"] || []) do
      {:ok, attachments} ->
        dispatch_message(thread_id, claimed(command, attachments))

      {:error, _} = error ->
        error
    end
  end

  def dispatch(%{"type" => "thread.fork", "targetThreadId" => thread_id} = command) do
    with :ok <- T3.Orchestration.Fork.fork(command),
         do: {:ok, %{"sequence" => sequence(thread_id)}}
  end

  def dispatch(%{"type" => "thread.merge_back", "targetThreadId" => thread_id} = command) do
    with :ok <- T3.Orchestration.Fork.merge_back(command),
         do: {:ok, %{"sequence" => sequence(thread_id)}}
  end

  # An empty thread; launch_thread also sends a first message.
  def dispatch(%{"type" => "thread.create", "threadId" => thread_id} = command) do
    thread =
      command
      |> Entities.thread(Entities.now())
      |> Map.merge(Map.take(command, ~w(branch worktreePath)))

    created =
      T3.Streams.transact(thread_id, :thread, fn state ->
        if StreamState.get(state, "thread")[thread_id],
          do: {[], {:error, "Thread #{thread_id} already exists."}},
          else: {[create("thread", thread_id, thread)], :ok}
      end)

    with :ok <- created, do: {:ok, %{"sequence" => sequence(thread_id)}}
  end

  # Stops the thread's provider process ("Stop session"). The next run starts it
  # again and resumes the provider thread.
  def dispatch(%{"type" => "provider-session.detach", "threadId" => thread_id} = command) do
    session_id = command["providerSessionId"]

    detached =
      T3.Streams.transact(thread_id, :thread, fn state ->
        cond do
          Enum.any?(StreamState.list(state, "run"), &(&1["status"] in @active_statuses)) ->
            {[], {:error, "Interrupt the current turn before stopping the session."}}

          StreamState.get(state, "provider-session")[session_id] ->
            {[{"provider-session", session_id, Patch.delete()}], :ok}

          true ->
            {[], :ok}
        end
      end)

    with :ok <- detached do
      stop_runtimes(thread_id)
      {:ok, %{"sequence" => sequence(thread_id)}}
    end
  end

  def dispatch(%{"type" => "checkpoint.rollback", "threadId" => thread_id} = command) do
    with :ok <- T3.Orchestration.Rollback.run(command),
         do: {:ok, %{"sequence" => sequence(thread_id)}}
  end

  def dispatch(%{"type" => "run.interrupt", "threadId" => thread_id} = command) do
    with :ok <- interrupt_any(thread_id, command["runId"]),
         do: {:ok, %{"sequence" => sequence(thread_id)}}
  end

  def dispatch(%{"type" => "queued-run.cancel", "threadId" => thread_id, "runId" => run_id}) do
    queue_change(thread_id, fn state ->
      at = Entities.now()

      [
        upsert(
          state,
          "run",
          run_id,
          &if(&1["status"] == "queued",
            do:
              Map.merge(&1, %{
                "status" => "cancelled",
                "queuePosition" => nil,
                "completedAt" => at
              })
          )
        )
      ]
    end)
  end

  def dispatch(
        %{"type" => "queued-run.edit", "threadId" => thread_id, "runId" => run_id} = command
      ) do
    queue_change(thread_id, fn state ->
      case StreamState.get(state, "run")[run_id] do
        %{"status" => "queued", "userMessageId" => message_id} ->
          [
            upsert(
              state,
              "message",
              message_id,
              &Map.merge(&1, %{"text" => command["text"] || "", "updatedAt" => Entities.now()})
            )
          ]

        _ ->
          []
      end
    end)
  end

  def dispatch(
        %{"type" => "queued-run.reorder", "threadId" => thread_id, "runId" => run_id} = command
      ) do
    queue_change(thread_id, fn state ->
      queued = queued_runs(state) |> Enum.map(& &1["id"]) |> List.delete(run_id)

      order =
        case Enum.find_index(queued, &(&1 == command["beforeRunId"])) do
          nil -> queued ++ [run_id]
          index -> List.insert_at(queued, index, run_id)
        end

      for {id, position} <- Enum.with_index(order, 1),
          do: upsert(state, "run", id, &Map.put(&1, "queuePosition", position))
    end)
  end

  # Commands that set fields on the thread itself.
  def dispatch(%{"type" => type, "threadId" => thread_id} = command)
      when type in @thread_updates do
    at = Entities.now()

    result =
      T3.Streams.transact(thread_id, :thread, fn state ->
        case StreamState.get(state, "thread")[thread_id] do
          nil ->
            {[], {:error, "unknown thread #{thread_id}"}}

          thread ->
            case thread_fields(type, command, thread, at) do
              {:error, _} = error ->
                {[], error}

              fields ->
                change = upsert(state, "thread", thread_id, &Map.merge(&1, fields))
                {Enum.reject([change | archived_queue(type, state, at)], &is_nil/1), :ok}
            end
        end
      end)

    with :ok <- result do
      if type == "thread.metadata.update" and command["regenerateTitle"] == true,
        do: regenerate_title(thread_id)

      {:ok, %{"sequence" => sequence(thread_id)}}
    end
  end

  # A queued message steers the running turn when its provider can take it; otherwise
  # it goes first and the run is interrupted, which starts it next.
  def dispatch(%{"type" => "queued-message.promote-to-steer", "threadId" => thread_id} = command) do
    state = T3.Streams.Server.state(T3.Streams.ensure(thread_id))
    runs = StreamState.get(state, "run")
    queued = runs[command["queuedRunId"]]
    target = runs[command["targetRunId"]]
    message = queued && StreamState.get(state, "message")[queued["userMessageId"]]

    if queued && message && target && target["status"] in @active_statuses &&
         steerable?(target) &&
         runtime(target["providerInstanceId"]).steer(thread_id, target["id"], message["text"]) ==
           :ok do
      T3.Streams.transact(thread_id, :thread, fn state ->
        at = Entities.now()

        changes =
          [
            upsert(
              state,
              "run",
              queued["id"],
              &Map.merge(&1, %{
                "status" => "cancelled",
                "queuePosition" => nil,
                "completedAt" => at
              })
            ),
            upsert(state, "message", message["id"], &Map.put(&1, "runId", target["id"]))
          ] ++
            steer_changes(state, target, message["id"], message, "promoted_queued_to_steer", at)

        {Enum.reject(changes, &is_nil/1), :ok}
      end)

      T3.Streams.transact(thread_id, :thread, fn state -> {renumber(state), :ok} end)
      {:ok, %{"sequence" => sequence(thread_id)}}
    else
      restart_promoted(thread_id, command)
    end
  end

  # After a restart the queue waits until the user resumes it.
  def dispatch(%{"type" => "queue.resume", "threadId" => thread_id}) do
    with {:ok, result} <-
           queue_change(thread_id, fn state ->
             for run <- queued_runs(state),
                 do: upsert(state, "run", run["id"], &Map.put(&1, "queueHeld", false))
           end) do
      start_next(thread_id)
      {:ok, result}
    end
  end

  # An approval's decision, or answers to questions (`answers`, by question id).
  def dispatch(%{"type" => "runtime-request.respond", "threadId" => thread_id} = command) do
    with {:ok, response} <- response(thread_id, command),
         do: respond(thread_id, command["requestId"], response)
  end

  # Closing questions without answering them.
  def dispatch(%{"type" => "thread.user-input.dismiss", "threadId" => thread_id} = command),
    do: respond(thread_id, command["requestId"], %{"dismissed" => true})

  def dispatch(%{"type" => type}), do: {:error, "#{type} is not supported by this node yet"}

  defp response(thread_id, %{"answers" => %{} = answers} = command) do
    by_question = command["attachmentsByQuestionId"] || %{}

    claimed =
      Enum.reduce_while(by_question, {:ok, %{}}, fn {question, attachments}, {:ok, acc} ->
        case T3.Attachments.claim(thread_id, attachments) do
          {:ok, claimed} -> {:cont, {:ok, Map.put(acc, question, claimed)}}
          {:error, message} -> {:halt, {:error, message <> " Attach it again."}}
        end
      end)

    with {:ok, claimed} <- claimed do
      answer = %{
        "requestId" => command["requestId"],
        "answers" => answers,
        "attachmentsByQuestionId" => claimed
      }

      {:ok, %{"answers" => with_attachment_paths(answers, claimed), "questionAnswer" => answer}}
    end
  end

  defp response(_thread_id, command), do: {:ok, %{"decision" => command["decision"] || "decline"}}

  # Answers keep their provider's shape; files are named by where they are saved,
  # as the Node server words it.
  defp with_attachment_paths(answers, claimed) do
    Enum.reduce(claimed, answers, fn
      {_question, []}, answers ->
        answers

      {question, attachments}, answers ->
        text =
          Enum.map_join(attachments, "\n", fn attachment ->
            "Attached #{attachment["type"] || "file"} #{JSON.encode!(attachment["name"])}: " <>
              JSON.encode!(T3.Attachments.path(attachment) || "")
          end)

        Map.put(
          answers,
          question,
          case answers[question] do
            list when is_list(list) -> list ++ [text]
            answer when is_binary(answer) and answer != "" -> answer <> "\n\n" <> text
            _ -> text
          end
        )
    end)
  end

  @doc """
  Stops an idle thread's provider processes and marks its sessions stopped; the
  next run starts them again and resumes the provider's thread. Refused while a
  run is active.
  """
  def release_session(thread_id) do
    released =
      T3.Streams.transact(thread_id, :thread, fn state ->
        if Enum.any?(StreamState.list(state, "run"), &(&1["status"] in @active_statuses)) do
          {[], :busy}
        else
          at = Entities.now()

          changes =
            for session <- StreamState.list(state, "provider-session"),
                session["status"] != "stopped",
                do:
                  upsert(
                    state,
                    "provider-session",
                    session["id"],
                    &Map.merge(&1, %{"status" => "stopped", "updatedAt" => at})
                  )

          {changes, :ok}
        end
      end)

    if released == :ok, do: stop_runtimes(thread_id)
    released
  end

  defp stop_runtimes(thread_id) do
    for registry <- [T3.Codex.Registry, T3.Claude.Registry, T3.Acp.Registry],
        Process.whereis(registry) != nil,
        {pid, _} <- Registry.lookup(registry, thread_id),
        do: DynamicSupervisor.terminate_child(T3.Codex.Supervisor, pid)

    :ok
  end

  defp respond(thread_id, request_id, response) do
    result =
      Enum.find_value(
        [T3.Codex.ThreadRuntime, T3.Claude.ThreadRuntime, T3.Acp.ThreadRuntime],
        {:error, "no pending request"},
        fn runtime ->
          if runtime.respond(thread_id, request_id, response) == :ok, do: :ok
        end
      )

    with :ok <- result, do: {:ok, %{"sequence" => sequence(thread_id)}}
  end

  # A runtime that dies while starting the turn must not leave the run "starting"
  # forever: the run fails and the thread can take the next message.
  defp start_turn(thread_id, turn) do
    :ok = runtime(turn.ids.instance).start_turn(thread_id, turn)
  catch
    :exit, reason ->
      require Logger
      Logger.warning("turn failed to start in #{thread_id}: #{inspect(reason)}")

      T3.Orchestration.TurnWriter.finish(
        %{thread_id: thread_id, turn: turn},
        "failed",
        "The provider stopped while starting the turn."
      )
  end

  @doc """
  Creates a thread, in the project root, an existing worktree, or a new worktree,
  and sends its first message when there is one (`orchestration.launchThread`). A
  new worktree is prepared first (`T3.WorktreeSetup`), with the message's run
  waiting as `preparing` until it is ready.
  """
  @spec launch_thread(map) :: {:ok, map} | {:error, String.t()}
  def launch_thread(input) do
    thread_id = input["threadId"] || T3.Environment.uuid4()
    strategy = input["workspaceStrategy"] || %{"type" => "root"}
    at = Entities.now()

    thread =
      Entities.thread(Map.put(input, "threadId", thread_id), at)
      |> Map.merge(workspace_fields(strategy))
      # A delegated task's thread is a subagent of the thread that asked for it.
      |> Map.merge(Map.take(input, ["lineage"]))

    {:ok, created} =
      T3.Streams.transact(thread_id, :thread, fn state ->
        case StreamState.get(state, "thread")[thread_id] do
          nil -> {[{"thread", thread_id, Patch.diff(nil, thread)}], {:ok, :created}}
          _ -> {[], {:ok, :resumed}}
        end
      end)

    result = %{"threadId" => thread_id, "resumed" => created == :resumed}

    case input["initialMessage"] do
      nil ->
        {:ok, result}

      message ->
        if input["generateTitle"] == true and (message["text"] || "") != "",
          do: generate_title(thread_id, message["text"])

        command =
          Map.merge(message, %{
            "type" => "message.dispatch",
            "commandId" => "#{input["commandId"]}:initial-message",
            "threadId" => thread_id,
            "createdBy" => input["createdBy"] || "user",
            "creationSource" => input["creationSource"] || "web",
            "modelSelection" => input["modelSelection"]
          })

        launched =
          if strategy["type"] == "worktree" and created == :created,
            do: launch_in_worktree(thread_id, thread, strategy, command),
            else: dispatch(command)

        with {:ok, _} <- launched, do: {:ok, result}
    end
  end

  defp workspace_fields(%{"type" => "existing_worktree"} = strategy),
    do: %{"worktreePath" => strategy["worktreePath"], "branch" => strategy["branch"]}

  defp workspace_fields(%{"type" => "root", "branch" => branch}) when is_binary(branch),
    do: %{"branch" => branch}

  defp workspace_fields(_strategy), do: %{"branch" => nil}

  defp launch_in_worktree(thread_id, thread, strategy, command) do
    project =
      case T3.Shell.row(node(), thread["projectId"]) do
        {"project", row} -> row
        _ -> nil
      end

    with %{"workspaceRoot" => _} <- project || {:error, "The project is not on this node."},
         {:ok, attachments} <- T3.Attachments.claim(thread_id, command["attachments"] || []),
         command =
           command
           |> claimed(attachments)
           |> Map.put("dispatchMode", %{"type" => "defer_start"}),
         {:ok, {:prepared, run_id}} <-
           T3.Streams.transact(thread_id, :thread, &decide_message(&1, thread_id, command)) do
      :ok = T3.WorktreeSetup.start(thread_id, run_id, project, strategy, command["text"])
      {:ok, %{"sequence" => sequence(thread_id)}}
    end
  end

  # Titles a thread from its first message's `text`, in the background; the thread
  # keeps its own title until one arrives. A regenerated title that fails clears
  # the thread's in-flight mark.
  defp generate_title(thread_id, text, regenerating \\ false) do
    Task.start(fn ->
      root =
        case T3.Shell.row(node(), thread_id) do
          {"thread", row} -> row["worktreePath"] || project_root(row["projectId"])
          _ -> nil
        end

      with true <- is_binary(text) and text != "",
           {:ok, %{"title" => title}} <-
             T3.TextGeneration.thread_title(root || System.tmp_dir!(), text),
           title when title != "" <- title |> String.trim() |> String.slice(0, 80) do
        dispatch(%{"type" => "thread.metadata.update", "threadId" => thread_id, "title" => title})
      else
        failure ->
          require Logger
          Logger.warning("thread title not generated: #{inspect(failure)}")

          if regenerating,
            do:
              dispatch(%{
                "type" => "thread.metadata.update",
                "threadId" => thread_id,
                "regenerateTitle" => false
              })
      end
    end)
  end

  defp regenerate_title(thread_id) do
    text =
      T3.Streams.Server.state(T3.Streams.ensure(thread_id))
      |> StreamState.list("message")
      |> Enum.find_value(&(&1["role"] == "user" and (&1["text"] || "") != "" and &1["text"]))

    generate_title(thread_id, text, true)
  end

  @doc "Starts the run a prepared workspace was waiting for."
  def release_prepared(thread_id, run_id) do
    decide = fn state ->
      thread = StreamState.get(state, "thread")[thread_id]
      runs = StreamState.list(state, "run")

      with %{"status" => "preparing"} = run <- StreamState.get(state, "run")[run_id],
           %{} = message <- StreamState.get(state, "message")[run["userMessageId"]] do
        new_run(state, thread, runs, message, run)
      else
        _ -> {[], {:error, "the run is not waiting for its workspace"}}
      end
    end

    case T3.Streams.transact(thread_id, :thread, decide) do
      {:ok, turn} ->
        :ok = T3.Checkpoint.baseline(turn.cwd, turn.scope_id, turn.run_ordinal - 1)
        start_turn(thread_id, turn)

      {:error, _} = error ->
        error
    end
  end

  @doc "Ends a run whose workspace could not be prepared (`failed` or `cancelled`)."
  def fail_prepared(thread_id, run_id, status) do
    T3.Streams.transact(thread_id, :thread, fn state ->
      change =
        upsert(state, "run", run_id, fn
          %{"status" => "preparing"} = run ->
            Map.merge(run, %{"status" => status, "completedAt" => Entities.now()})

          run ->
            run
        end)

      {Enum.reject([change], &is_nil/1), :ok}
    end)

    start_next(thread_id)
  end

  # The provider driver for an instance: its own id for ACP agents.
  @doc "The driver behind a provider instance."
  def driver_for("claudeAgent"), do: "claudeAgent"

  def driver_for(instance) do
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

  defp dispatch_message(thread_id, command) do
    case T3.Streams.transact(thread_id, :thread, &decide_message(&1, thread_id, command)) do
      {:ok, :queued} ->
        {:ok, %{"sequence" => sequence(thread_id)}}

      {:ok, {:steer, run}} ->
        steer(thread_id, run, command)

      {:ok, {:restart, active_run_id}} ->
        # The queued message goes first; the interrupted run's end starts it.
        _ = interrupt_any(thread_id, active_run_id)
        {:ok, %{"sequence" => sequence(thread_id)}}

      {:ok, turn} ->
        :ok = T3.Checkpoint.baseline(turn.cwd, turn.scope_id, turn.run_ordinal - 1)
        start_turn(thread_id, turn)
        {:ok, %{"sequence" => sequence(thread_id)}}

      {:error, _} = error ->
        error
    end
  end

  defp sequence(thread_id), do: T3.Streams.Server.state(T3.Streams.ensure(thread_id)).seq

  defp restart_promoted(thread_id, command) do
    queued_id = command["queuedRunId"]

    with {:ok, result} <-
           queue_change(thread_id, fn state ->
             order = [
               queued_id | queued_runs(state) |> Enum.map(& &1["id"]) |> List.delete(queued_id)
             ]

             for {id, position} <- Enum.with_index(order, 1),
                 do: upsert(state, "run", id, &Map.put(&1, "queuePosition", position))
           end) do
      _ = interrupt_any(thread_id, command["targetRunId"])
      {:ok, result}
    end
  end

  # A message's inline context records (`T3.ComposerContext`) travel with its text.
  defp with_context(entity, %{"context" => %{} = context}),
    do: Map.put(entity, "context", context)

  defp with_context(entity, _source), do: entity

  # Uploads claimed into the thread, with the context records that name them.
  defp claimed(command, attachments) do
    command
    |> Map.put("attachments", attachments)
    |> Map.put(
      "context",
      T3.ComposerContext.remap_attachments(
        command["context"],
        command["attachments"] || [],
        attachments
      )
    )
  end

  defp steerable?(run),
    do: driver_for(run["providerInstanceId"] || "codex") in ["codex", "claudeAgent"]

  # The provider takes the message first; only then does it join the run. If the turn
  # ended meanwhile, the message is sent like any other (queued or started).
  defp steer(thread_id, run, command) do
    text = T3.ComposerContext.for_provider(command["text"] || "", command["context"])

    case runtime(run["providerInstanceId"] || "codex").steer(thread_id, run["id"], text) do
      :ok ->
        T3.Streams.transact(thread_id, :thread, fn state ->
          at = Entities.now()
          message_id = command["messageId"] || Entities.new_id("message")
          ids = %{thread: thread_id, run: run["id"], root_node: run["rootNodeId"]}

          message =
            Entities.message(ids, message_id, "user", command["text"] || "", false, at)
            |> Map.merge(%{
              "attachments" => command["attachments"] || [],
              "createdBy" => command["createdBy"] || "user",
              "creationSource" => command["creationSource"] || "web"
            })
            |> with_context(command)

          {[create("message", message_id, message)] ++
             steer_changes(state, run, message_id, message, "steer", at), :ok}
        end)

        {:ok, %{"sequence" => sequence(thread_id)}}

      {:error, _reason} ->
        command
        |> Map.put("dispatchMode", %{"type" => "queue_after_active"})
        |> Map.delete("deliveryIntent")
        |> dispatch()
    end
  end

  # The steered message's place in the transcript, inside the run it joined.
  defp steer_changes(state, run, message_id, message, intent, at) do
    item_id = "turn-item:user:#{message_id}"

    ids = %{
      thread: run["threadId"],
      run: run["id"],
      root_node: run["rootNodeId"],
      provider_thread: run["providerThreadId"]
    }

    [
      create(
        "turn-item",
        item_id,
        Entities.turn_item(ids, item_id, "user_message", next_ordinal(state), "completed", at, %{
          "createdBy" => message["createdBy"] || "user",
          "creationSource" => message["creationSource"] || "web",
          "messageId" => message_id,
          "inputIntent" => intent,
          "text" => message["text"] || "",
          "attachments" => message["attachments"] || []
        })
        |> with_context(message)
      )
    ]
  end

  # The thread fields a command sets, as the Node server's projector sets them.
  defp thread_fields("thread.archive", _, _, at), do: %{"archivedAt" => at}
  defp thread_fields("thread.unarchive", _, _, _), do: %{"archivedAt" => nil}
  defp thread_fields("thread.delete", _, _, at), do: %{"deletedAt" => at}

  defp thread_fields("thread.settle", command, _, at),
    do: %{"settledOverride" => "settled", "settledAt" => command["settledAt"] || at}

  defp thread_fields("thread.unsettle", _, _, at),
    do: %{"settledOverride" => "active", "settledAt" => nil, "unsettledAt" => at}

  defp thread_fields("thread.snooze", command, _, at),
    do: %{"snoozedUntil" => command["snoozedUntil"], "snoozedAt" => at}

  defp thread_fields("thread.unsnooze", _, _, _), do: %{"snoozedUntil" => nil, "snoozedAt" => nil}

  defp thread_fields("thread.pin", command, _, at),
    do: %{"pinnedAt" => at, "pinOrderKey" => command["orderKey"]}

  defp thread_fields("thread.unpin", _, _, _), do: %{"pinnedAt" => nil, "pinOrderKey" => nil}

  defp thread_fields("thread.pin.reorder", command, _, _),
    do: %{"pinOrderKey" => command["orderKey"]}

  defp thread_fields("thread.active.reorder", command, _, _),
    do: %{"activeOrderKey" => command["orderKey"]}

  # Visits only move forward, so a late or replayed visit changes nothing.
  defp thread_fields("thread.visit", command, thread, _) do
    visited = command["visitedAt"]

    if is_binary(thread["lastVisitedAt"]) and thread["lastVisitedAt"] >= visited,
      do: %{},
      else: %{"lastVisitedAt" => visited}
  end

  defp thread_fields("thread.mark-unread", _, _, _), do: %{"lastVisitedAt" => nil}

  defp thread_fields("thread.runtime-mode.set", command, _, at),
    do: %{"runtimeMode" => command["runtimeMode"], "updatedAt" => at}

  defp thread_fields("thread.interaction-mode.set", command, _, at),
    do: %{"interactionMode" => command["interactionMode"], "updatedAt" => at}

  # A thread's pull requests are keyed by host, repository and number.
  defp thread_fields("thread.pull-request.link", command, thread, at) do
    link =
      command
      |> Map.take(~w(host repository number url source))
      |> Map.merge(%{"linkedAt" => at, "snapshot" => nil, "stack" => nil})

    %{"pullRequests" => other_pull_requests(thread, command) ++ [link], "updatedAt" => at}
  end

  defp thread_fields("thread.pull-request.unlink", command, thread, at),
    do: %{"pullRequests" => other_pull_requests(thread, command), "updatedAt" => at}

  # The next run starts the new provider's thread with the conversation handed over.
  defp thread_fields("provider.switch", command, thread, at),
    do: thread_fields("thread.model-selection.set", command, thread, at)

  defp thread_fields("thread.model-selection.set", %{"modelSelection" => selection}, _, at),
    do: %{
      "modelSelection" => selection,
      "providerInstanceId" => selection["instanceId"],
      "updatedAt" => at
    }

  defp thread_fields("thread.metadata.update", command, thread, at) do
    cond do
      Map.has_key?(command, "expectedWorktreePath") and
          command["expectedWorktreePath"] != thread["worktreePath"] ->
        {:error, "the thread's worktree changed"}

      true ->
        command
        |> Map.take(~w(title branch worktreePath limitRecovery linkedPullRequest))
        |> Map.put("updatedAt", at)
        |> Map.merge(title_regeneration(command, at))
    end
  end

  # An archived thread's queued messages will not run.
  defp archived_queue("thread.archive", state, at) do
    for run <- queued_runs(state) do
      upsert(
        state,
        "run",
        run["id"],
        &Map.merge(&1, %{"status" => "cancelled", "queuePosition" => nil, "completedAt" => at})
      )
    end
  end

  defp archived_queue(_type, _state, _at), do: []

  # `regenerateTitle: true` marks a title in flight; a new title, or `false` when
  # generation failed, clears the mark.
  defp title_regeneration(%{"regenerateTitle" => true} = command, at),
    do: %{"titleRegeneration" => %{"requestId" => command["commandId"], "startedAt" => at}}

  defp title_regeneration(command, _at) do
    if command["regenerateTitle"] == false or Map.has_key?(command, "title"),
      do: %{"titleRegeneration" => nil},
      else: %{}
  end

  defp other_pull_requests(thread, key) do
    Enum.reject(
      thread["pullRequests"] || [],
      &(Map.take(&1, ~w(host repository number)) == Map.take(key, ~w(host repository number)))
    )
  end

  # Changes to queued runs; positions are renumbered 1.. after each one.
  defp queue_change(thread_id, fun) do
    T3.Streams.transact(thread_id, :thread, fn state ->
      changes = Enum.reject(fun.(state), &is_nil/1)
      {changes, :ok}
    end)

    T3.Streams.transact(thread_id, :thread, fn state -> {renumber(state), :ok} end)
    {:ok, %{"sequence" => sequence(thread_id)}}
  end

  defp queued_runs(state) do
    state
    |> StreamState.list("run")
    |> Enum.filter(&(&1["status"] == "queued"))
    |> Enum.sort_by(&{&1["queuePosition"] || 0, &1["ordinal"]})
  end

  defp renumber(state) do
    for {run, position} <- Enum.with_index(queued_runs(state), 1),
        change = upsert(state, "run", run["id"], &Map.put(&1, "queuePosition", position)),
        do: change
  end

  @doc """
  Starts the thread's first queued message if nothing is running and the queue is
  not held. Runtimes call it (off their own process) when a run ends.
  """
  def start_next(thread_id) do
    case T3.Streams.transact(thread_id, :thread, &decide_next(&1, thread_id)) do
      {:ok, turn} ->
        :ok = T3.Checkpoint.baseline(turn.cwd, turn.scope_id, turn.run_ordinal - 1)
        start_turn(thread_id, turn)

      _idle ->
        :ok
    end
  end

  defp decide_next(state, thread_id) do
    thread = StreamState.get(state, "thread")[thread_id]
    runs = StreamState.list(state, "run")

    with false <- Enum.any?(runs, &(&1["status"] in @active_statuses)),
         %{} = next <- Enum.find(queued_runs(state), &(&1["queueHeld"] != true)),
         %{} = message <- StreamState.get(state, "message")[next["userMessageId"]] do
      {changes, result} = new_run(state, thread, runs, message, next)
      # The started run leaves the queue; the rest move up.
      rest = queued_runs(state) |> Enum.reject(&(&1["id"] == next["id"]))

      positions =
        for {run, position} <- Enum.with_index(rest, 1),
            change = upsert(state, "run", run["id"], &Map.put(&1, "queuePosition", position)),
            do: change

      {changes ++ positions, result}
    else
      _ -> {[], :idle}
    end
  end

  # Records the user's message and a new run, and returns what the provider needs to
  # start the turn. Rejects a second run while one is active.
  defp decide_message(state, thread_id, command) do
    thread = StreamState.get(state, "thread")[thread_id]
    runs = StreamState.list(state, "run")

    cond do
      thread == nil ->
        {[], {:error, "unknown thread #{thread_id}"}}

      get_in(command, ["dispatchMode", "type"]) == "defer_start" ->
        prepare_run(state, thread, runs, command)

      active = Enum.find(runs, &(&1["status"] in @active_statuses)) ->
        intent = command["deliveryIntent"]
        mode = get_in(command, ["dispatchMode", "type"])
        steer = intent == "steer" or mode == "steer_active"

        # As the Node server resolves it: steer a running turn that can take it,
        # else queue; a restart (or a steer that cannot be) interrupts and goes first.
        auto_steer =
          intent in [nil, "auto"] and mode != "queue_after_active" and
            active["status"] in ["running", "waiting"]

        cond do
          intent == "restart" or mode == "restart_active" ->
            queue_run(state, thread, runs, command, active["id"])

          (steer or auto_steer) and steerable?(active) ->
            {[], {:ok, {:steer, active}}}

          steer ->
            queue_run(state, thread, runs, command, active["id"])

          true ->
            queue_run(state, thread, runs, command, nil)
        end

      true ->
        new_run(state, thread, runs, command)
    end
  end

  # A message whose run waits for its workspace (`release_prepared/2`).
  defp prepare_run(state, thread, runs, command) do
    {changes, {:ok, :queued}} = queue_run(state, thread, runs, command, nil)

    [{"run", run_id, %{"s" => run}} | rest] = changes
    run = Map.merge(run, %{"status" => "preparing", "queuePosition" => nil})
    {[{"run", run_id, %{"s" => run}} | rest], {:ok, {:prepared, run_id}}}
  end

  # A message for later: its run waits in the queue, with the message itself. A
  # restart puts it first and asks for the active run to be interrupted.
  defp queue_run(state, thread, runs, command, restart_of) do
    at = Entities.now()
    selection = command["modelSelection"] || thread["modelSelection"]
    instance = selection["instanceId"] || thread["providerInstanceId"] || "codex"
    driver = driver_for(instance)
    message_id = command["messageId"] || Entities.new_id("message")

    ids = %{
      driver: driver,
      instance: instance,
      thread: thread["id"],
      run: Entities.new_id("run"),
      attempt: nil,
      root_node: nil,
      provider_thread: "provider-thread:#{driver}:#{thread["id"]}",
      message: message_id
    }

    queued = queued_runs(state)
    position = if restart_of, do: 0, else: length(queued) + 1

    run =
      Entities.run(ids, length(runs) + 1, selection, at)
      |> Map.merge(%{"status" => "queued", "queuePosition" => position})

    message =
      Entities.message(ids, message_id, "user", command["text"] || "", false, at)
      |> Map.merge(%{
        "attachments" => command["attachments"] || [],
        "createdBy" => command["createdBy"] || "user",
        "creationSource" => command["creationSource"] || "web"
      })
      |> with_context(command)

    # A restart's message goes first; the others move down one.
    shifted =
      if restart_of,
        do:
          for(
            {queued_run, index} <- Enum.with_index(queued, 2),
            change = upsert(state, "run", queued_run["id"], &Map.put(&1, "queuePosition", index)),
            do: change
          ),
        else: []

    run = if restart_of, do: Map.put(run, "queuePosition", 1), else: run

    {[create("run", ids.run, run), create("message", message_id, message)] ++ shifted,
     {:ok, if(restart_of, do: {:restart, restart_of}, else: :queued)}}
  end

  # Starts a run for a message: a new one, or a queued run (with its stored message
  # as `command`), which keeps its ordinal and ids.
  defp new_run(state, thread, runs, command, queued \\ nil) do
    at = Entities.now()
    thread_id = thread["id"]
    ordinal = if queued, do: queued["ordinal"], else: length(runs) + 1

    selection =
      (queued && queued["modelSelection"]) || command["modelSelection"] ||
        thread["modelSelection"]

    instance = selection["instanceId"] || thread["providerInstanceId"] || "codex"
    driver = driver_for(instance)
    provider_thread_id = "provider-thread:#{driver}:#{thread_id}"
    session_id = "provider-session:#{driver}:#{thread_id}"
    cwd = thread["worktreePath"] || project_root(thread["projectId"]) || File.cwd!()

    message_id =
      (queued && queued["userMessageId"]) || command["messageId"] || Entities.new_id("message")

    ids = %{
      driver: driver,
      instance: instance,
      thread: thread_id,
      run: (queued && queued["id"]) || Entities.new_id("run"),
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
    fresh_session =
      Entities.provider_session(session_id, cwd, selection["model"], at, driver, instance)

    # A session made by an older server takes on what this one can do.
    session_change =
      if StreamState.get(state, "provider-session")[session_id],
        do:
          upsert(
            state,
            "provider-session",
            session_id,
            # A session stopped while idle is ready again.
            &Map.merge(&1, %{
              "capabilities" => fresh_session["capabilities"],
              "status" => "ready",
              "cwd" => cwd
            })
          ),
        else: create("provider-session", session_id, fresh_session)

    provider_changes =
      if provider_thread do
        [
          session_change,
          upsert(
            state,
            "provider-thread",
            provider_thread_id,
            # A rolled-back head is where this run resumes the conversation.
            &Map.merge(&1, %{
              "lastRunOrdinal" => ordinal,
              "providerSessionId" => session_id,
              "nativeConversationHeadRef" => nil
            })
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
      Enum.reject(provider_changes ++ [scope_change], &is_nil/1)
      |> Kernel.++(
        [
          if(queued,
            do:
              upsert(
                state,
                "run",
                ids.run,
                &Map.merge(
                  &1,
                  Map.drop(Entities.run(ids, ordinal, selection, at), ["requestedAt"])
                )
              ),
            else: create("run", ids.run, Entities.run(ids, ordinal, selection, at))
          ),
          create("run-attempt", ids.attempt, Entities.attempt(ids)),
          create(
            "node",
            ids.root_node,
            Entities.node(ids, ids.root_node, "root_turn", "pending", at, %{
              "checkpointScopeId" => scope_id
            })
          ),
          unless(queued,
            do:
              create(
                "message",
                message_id,
                Entities.message(ids, message_id, "user", text, false, at, %{
                  "attachments" => command["attachments"] || []
                })
                |> with_context(command)
              )
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
                "inputIntent" =>
                  if(queued && queued["status"] == "queued",
                    do: "queued_turn",
                    else: "turn_start"
                  ),
                "text" => text,
                "attachments" => command["attachments"] || []
              }
            )
            |> with_context(command)
          )
        ]
        |> Kernel.++([implemented_plan(state, thread_id, command["sourcePlanRef"])])
        |> Enum.reject(&is_nil/1)
      )

    handoff = T3.Orchestration.Handoff.plan(state, provider_thread, driver, ids.run, ordinal, at)

    turn = %{
      ids: ids,
      run_ordinal: ordinal,
      text:
        T3.Orchestration.Handoff.prompt(
          handoff.context,
          T3.ComposerContext.for_provider(text, command["context"])
        ),
      # A fork's first run continues the source's native thread from the fork point.
      fork: handoff.fork,
      cwd: cwd,
      scope_id: scope_id,
      model: selection["model"],
      runtime_mode: thread["runtimeMode"] || "full-access",
      interaction_mode: thread["interactionMode"] || "default",
      # The files providers read, from this node's attachment store.
      attachments:
        for(
          attachment <- command["attachments"] || [],
          path = T3.Attachments.path(attachment),
          do: %{
            type: attachment["type"],
            name: attachment["name"],
            mime_type: attachment["mimeType"],
            path: path
          }
        ),
      native_thread_id: get_in(provider_thread || %{}, ["nativeThreadRef", "nativeId"]),
      head: get_in(provider_thread || %{}, ["nativeConversationHeadRef", "nativeId"])
    }

    {changes ++ handoff.changes, {:ok, turn}}
  end

  # A message that implements a proposed plan of this thread completes it.
  defp implemented_plan(state, thread_id, %{"threadId" => thread_id, "planId" => plan_id}) do
    case StreamState.get(state, "plan")[plan_id] do
      %{"kind" => "proposed_plan"} ->
        upsert(state, "plan", plan_id, &Map.put(&1, "status", "completed"))

      _ ->
        nil
    end
  end

  defp implemented_plan(_state, _thread_id, _ref), do: nil

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
