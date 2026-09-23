defmodule T3.Mcp.Tools do
  @moduledoc """
  The tools of the `t3-code` MCP server (`T3.Mcp`), each acting as the thread whose
  agent called it. Definitions come from `priv/mcp_tools.json`; only the tools
  implemented here are advertised.

  The access rules follow the Node server's: a caller sees only threads of its own
  project; changing another thread needs a caller that is itself running, and never
  gives the target broader runtime or interaction modes than the caller has.
  """

  alias T3.{Orchestration, StreamState}

  @implemented ~w(t3_thread_list t3_thread_read t3_thread_send t3_thread_wait t3_thread_interrupt
                  t3_thread_search t3_environment_read t3_project_list t3_project_read
                  list_scheduled_tasks schedule_task delete_scheduled_task run_scheduled_task_now)

  @delegation ~w(delegate_task task_status task_cancel)
  @preview T3.Mcp.Preview.names()

  @runtime_ranks %{
    "approval-required" => 0,
    "auto-accept-edits" => 1,
    "auto" => 2,
    "full-access" => 3
  }
  @finished ~w(completed failed interrupted cancelled rolled_back)

  @doc "The advertised tools (MCP `tools/list`)."
  def list do
    for tool <- definitions(),
        tool["name"] in @implemented or tool["name"] in @delegation or
          tool["name"] in @preview do
      Map.take(tool, ["name", "description", "inputSchema"])
    end
  end

  defp definitions do
    case :persistent_term.get({__MODULE__, :definitions}, nil) do
      nil ->
        tools = Application.app_dir(:t3, "priv/mcp_tools.json") |> File.read!() |> JSON.decode!()
        :persistent_term.put({__MODULE__, :definitions}, tools)
        tools

      tools ->
        tools
    end
  end

  @doc "Runs a tool: `{:ok, result}` or `{:error, code, message}` (`OrchestratorMcpFailure`)."
  def call(name, args, caller) when name in @implemented do
    with {:ok, me} <- caller_row(caller), do: run(name, args, Map.put(caller, :row, me))
  end

  # Delegated tasks belong to their caller thread (`T3.Orchestration.Delegation`).
  def call("delegate_task", args, caller) do
    with {:ok, me} <- caller_row(caller),
         do: T3.Orchestration.Delegation.delegate(me, caller.instance, args)
  end

  def call("task_status", %{"taskId" => id}, caller),
    do: T3.Orchestration.Delegation.task_status(caller.thread_id, id)

  def call("task_cancel", %{"taskId" => id}, caller),
    do: T3.Orchestration.Delegation.cancel(caller.thread_id, id)

  def call(name, args, caller) when name in @preview, do: T3.Mcp.Preview.call(name, args, caller)

  def call(name, _args, _caller),
    do: {:error, "capability_denied", "#{name} is not available on this node."}

  # --- threads ---------------------------------------------------------------------

  defp run("t3_thread_list", args, %{row: me}) do
    statuses = args["statuses"]
    title = args["titleContains"] && String.downcase(args["titleContains"])

    threads =
      project_threads(me["projectId"])
      |> Enum.filter(
        &(statuses in [nil, []] or (&1["activityRunStatus"] || &1["status"]) in statuses)
      )
      |> Enum.filter(
        &(title == nil or String.contains?(String.downcase(&1["title"] || ""), title))
      )
      |> Enum.filter(
        &(args["includeSubagents"] != false or
            get_in(&1, ["lineage", "relationshipToParent"]) != "subagent")
      )

    cursor = args["cursor"] || 0
    page = Enum.slice(threads, cursor, args["limit"] || 50)

    {:ok,
     %{
       "projectId" => me["projectId"],
       "currentThreadId" => me["id"],
       "threads" => Enum.map(page, &list_item/1),
       "nextCursor" => if(cursor + length(page) < length(threads), do: cursor + length(page)),
       "total" => length(threads)
     }}
  end

  defp run("t3_thread_read", args, %{row: me}) do
    with {:ok, row} <- project_thread(me, args["threadId"]) do
      state = stream(row["id"])
      view = args["view"] || "messages"
      after_position = args["afterPosition"] || -1
      limit = args["limit"] || 50
      max_chars = args["maxCharsPerItem"] || 20_000
      messages = StreamState.get(state, "message")

      items =
        state
        |> StreamState.list("turn-item")
        |> Enum.filter(
          &(view == "activity" or &1["type"] in ["user_message", "assistant_message"])
        )
        |> Enum.filter(&(args["itemId"] == nil or &1["id"] == args["itemId"]))
        |> Enum.with_index()

      page =
        items
        |> Enum.filter(fn {_, position} -> position > after_position end)
        |> Enum.take(limit)

      {:ok,
       %{
         "thread" => Map.put(list_item(row), "totalItems", length(items)),
         "recentRuns" =>
           state
           |> StreamState.list("run")
           |> Enum.sort_by(& &1["ordinal"], :desc)
           |> Enum.take(args["runLimit"] || 10)
           |> Enum.map(&run_summary/1),
         "items" =>
           Enum.map(page, fn {item, position} ->
             timeline_item(item, position, messages, max_chars, args["textOffset"] || 0)
           end),
         "nextPosition" =>
           case List.last(page) do
             {_, position} -> position
             nil -> nil
           end,
         "hasMore" => length(items) > after_position + 1 + length(page)
       }}
    end
  end

  defp run("t3_thread_send", args, %{row: me} = caller) do
    with {:ok, row} <- project_thread(me, args["threadId"]),
         :ok <- live(caller),
         :ok <- no_escalation(me, row),
         :ok <-
           if(row["archivedAt"],
             do: {:error, "thread_not_sendable", "The thread is archived."},
             else: :ok
           ) do
      message_id = "message:mcp:" <> T3.Environment.uuid4()

      active = row["activeRunId"]

      # `auto` steers a running turn and starts one otherwise.
      mode =
        case {args["mode"] || "auto", active} do
          {"queue", _} -> %{"type" => "queue_after_active"}
          {"restart", _} -> %{"type" => "restart_active", "targetRunId" => active}
          {"auto", nil} -> %{"type" => "start_immediately"}
          _ -> %{"type" => "steer_active", "targetRunId" => active}
        end

      if mode["type"] in ["steer_active", "restart_active"] and row["activeRunId"] == nil do
        {:error, "thread_not_sendable", "The thread has no running turn to #{args["mode"]}."}
      else
        command = %{
          "type" => "message.dispatch",
          "commandId" => "command:mcp:" <> (args["clientRequestId"] || message_id),
          "threadId" => row["id"],
          "messageId" => message_id,
          "senderThreadId" => me["id"],
          "text" => args["message"],
          "attachments" => [],
          "dispatchMode" => mode,
          "createdBy" => "agent",
          "creationSource" => "mcp"
        }

        with {:ok, _} <- orchestration(Orchestration.dispatch(command)) do
          run = message_run(row["id"], message_id)

          {:ok,
           %{
             "threadId" => row["id"],
             "messageId" => message_id,
             "runId" => run && run["id"],
             "status" => (run && run["status"]) || "queued",
             "delivery" => mode["type"]
           }}
        end
      end
    end
  end

  defp run("t3_thread_wait", args, %{row: me}) do
    with {:ok, row} <- project_thread(me, args["threadId"]) do
      timeout = min(max(parse_number(args["timeoutMs"], 600_000), 1), 3_600_000)
      {run, timed_out} = wait(row["id"], args["runId"], timeout)

      {:ok,
       %{
         "threadId" => row["id"],
         "runId" => run && run["id"],
         "status" => (run && run["status"]) || "idle",
         "timedOut" => timed_out
       }}
    end
  end

  defp run("t3_thread_interrupt", args, %{row: me} = caller) do
    with {:ok, row} <- project_thread(me, args["threadId"]),
         :ok <- live(caller),
         {:ok, _} <-
           orchestration(
             Orchestration.dispatch(%{
               "type" => "run.interrupt",
               "commandId" =>
                 "command:mcp:" <> (args["clientRequestId"] || T3.Environment.uuid4()),
               "threadId" => row["id"],
               "runId" => args["runId"] || row["activeRunId"]
             })
           ) do
      {:ok,
       %{
         "threadId" => row["id"],
         "runId" => args["runId"] || row["activeRunId"],
         "interrupted" => true
       }}
    end
  end

  defp run("t3_thread_search", args, %{row: me}) do
    {:ok, %{"matches" => matches}} = T3.Search.threads(Map.take(args, ["query", "limit"]))
    {:ok, %{"matches" => Enum.filter(matches, &(&1["projectId"] == me["projectId"]))}}
  end

  # --- environment and projects ------------------------------------------------------

  defp run("t3_environment_read", _args, %{row: me}) do
    environment = T3.Environment.descriptor()

    {:ok,
     %{
       "environmentId" => environment["environmentId"],
       "label" => environment["label"],
       "platform" => environment["platform"],
       "currentThreadId" => me["id"],
       "currentProjectId" => me["projectId"],
       "providers" =>
         for provider <- T3.Environment.providers(), provider["enabled"] != false do
           %{
             "providerInstanceId" => provider["instanceId"],
             "driver" => provider["driver"],
             "status" => provider["status"],
             "models" => for(model <- provider["models"] || [], do: model["slug"])
           }
         end
     }}
  end

  defp run("t3_project_list", args, _caller) do
    projects =
      for {{node, _}, {"project", row}} <- T3.Shell.rows(),
          node == node() and row["deletedAt"] == nil,
          do: project(row)

    cursor = args["cursor"] || 0
    page = Enum.slice(projects, cursor, args["limit"] || 50)

    {:ok,
     %{
       "projects" => page,
       "nextCursor" => if(cursor + length(page) < length(projects), do: cursor + length(page)),
       "total" => length(projects)
     }}
  end

  defp run("t3_project_read", %{"projectId" => id}, _caller) do
    case T3.Shell.row(node(), id) do
      {"project", %{"deletedAt" => nil} = row} -> {:ok, %{"project" => project(row)}}
      _ -> {:error, "invalid_request", "The project was not found."}
    end
  end

  # --- scheduled tasks ----------------------------------------------------------------

  defp run("list_scheduled_tasks", _args, %{row: me}) do
    {:ok, %{"tasks" => tasks}} = T3.ScheduledTasks.list()
    {:ok, %{"tasks" => Enum.filter(tasks, &(&1["projectId"] == me["projectId"]))}}
  end

  defp run("schedule_task", args, %{row: me} = caller) do
    with :ok <- live(caller) do
      input =
        %{
          "title" => args["title"] || String.slice(args["prompt"] || "", 0, 60),
          "prompt" => args["prompt"],
          "enabled" => args["enabled"] != false,
          "schedule" => args["schedule"],
          "projectId" => me["projectId"],
          "threadId" => if(args["bindToCurrentThread"] == false, do: nil, else: me["id"]),
          "workspaceStrategy" => %{"type" => "root"},
          "modelSelection" => me["modelSelection"],
          "runtimeMode" => me["runtimeMode"],
          "interactionMode" => me["interactionMode"],
          "createdBy" => "agent",
          "creationSource" => "mcp"
        }

      case T3.ScheduledTasks.upsert(input) do
        {:ok, %{"task" => task}} -> {:ok, %{"task" => task}}
        {:error, %{"message" => message}} -> {:error, "invalid_request", message}
      end
    end
  end

  defp run("delete_scheduled_task", %{"scheduledTaskId" => id}, %{row: me} = caller) do
    with :ok <- live(caller),
         :ok <- own_task(me, id) do
      {:ok, _} = T3.ScheduledTasks.delete(%{"id" => id})
      {:ok, %{"taskId" => id, "deleted" => true}}
    end
  end

  defp run("run_scheduled_task_now", %{"taskId" => id}, %{row: me} = caller) do
    with :ok <- live(caller),
         :ok <- own_task(me, id) do
      case T3.ScheduledTasks.run_now(%{"id" => id}) do
        {:ok, %{"task" => task}} ->
          {:ok,
           Map.take(task, ~w(threadId lastRunStatus runCount nextRunAt)) |> Map.put("taskId", id)}

        {:error, %{"message" => message}} ->
          {:error, "orchestration_error", message}
      end
    end
  end

  # --- access ---------------------------------------------------------------------------

  defp caller_row(%{thread_id: id}) do
    case T3.Shell.row(node(), id) do
      {"thread", %{"deletedAt" => nil} = row} -> {:ok, row}
      _ -> {:error, "thread_not_found", "The calling thread was not found."}
    end
  end

  defp project_thread(me, nil), do: {:ok, me}

  defp project_thread(%{"projectId" => project}, id) do
    case T3.Shell.row(node(), id) do
      {"thread", %{"deletedAt" => nil, "projectId" => ^project} = row} ->
        {:ok, row}

      _ ->
        {:error, "thread_not_found", "The thread was not found in the calling project."}
    end
  end

  # Only a caller that is itself running may change things. Read from its stream:
  # sidebar rows trail a run's end.
  defp live(%{row: me, instance: instance}) do
    running =
      stream(me["id"])
      |> StreamState.list("run")
      |> Enum.any?(&(&1["status"] in ~w(starting running waiting)))

    if me["archivedAt"] == nil and running and me["providerInstanceId"] in [nil, instance],
      do: :ok,
      else:
        {:error, "parent_not_active", "The calling provider no longer owns an active thread run."}
  end

  defp no_escalation(me, target) do
    cond do
      rank(target["runtimeMode"]) > rank(me["runtimeMode"]) ->
        {:error, "runtime_mode_escalation_denied",
         "Thread runtime mode #{target["runtimeMode"]} is broader than the caller's #{me["runtimeMode"]}."}

      target["interactionMode"] != "plan" and me["interactionMode"] == "plan" ->
        {:error, "interaction_mode_escalation_denied",
         "Thread interaction mode #{target["interactionMode"]} is broader than the caller's plan mode."}

      true ->
        :ok
    end
  end

  defp rank(mode), do: Map.get(@runtime_ranks, mode, 3)

  defp own_task(me, id) do
    {:ok, %{"tasks" => tasks}} = T3.ScheduledTasks.list()

    if Enum.any?(tasks, &(&1["id"] == id and &1["projectId"] == me["projectId"])),
      do: :ok,
      else: {:error, "invalid_request", "The task was not found in the calling project."}
  end

  # --- helpers --------------------------------------------------------------------------

  defp project_threads(project_id) do
    for(
      {{node, _}, {"thread", row}} <- T3.Shell.rows(),
      node == node() and row["projectId"] == project_id and row["deletedAt"] == nil,
      do: row
    )
    |> Enum.sort_by(&(&1["updatedAt"] || ""), :desc)
  end

  defp list_item(row) do
    %{
      "threadId" => row["id"],
      "title" => row["title"],
      "status" => row["activityRunStatus"] || row["status"],
      "providerInstanceId" => row["providerInstanceId"],
      "model" => get_in(row, ["modelSelection", "model"]),
      "runtimeMode" => row["runtimeMode"],
      "interactionMode" => row["interactionMode"],
      "branch" => row["branch"],
      "worktreePath" => row["worktreePath"],
      "activeRunId" => row["activeRunId"],
      "latestRunId" => row["latestRunId"],
      "archived" => row["archivedAt"] != nil,
      "parentThreadId" => get_in(row, ["lineage", "parentThreadId"]),
      "updatedAt" => row["updatedAt"]
    }
  end

  defp run_summary(run),
    do: %{
      "runId" => run["id"],
      "ordinal" => run["ordinal"],
      "status" => run["status"],
      "requestedAt" => run["requestedAt"],
      "startedAt" => run["startedAt"],
      "completedAt" => run["completedAt"]
    }

  defp timeline_item(item, position, messages, max_chars, offset) do
    text =
      (item["messageId"] && get_in(messages, [item["messageId"], "text"])) || item["text"] ||
        item["title"] || item["markdown"] || ""

    rest = String.slice(text, offset, String.length(text))

    %{
      "position" => position,
      "itemId" => item["id"],
      "type" => item["type"],
      "runId" => item["runId"],
      "status" => item["status"],
      "text" => String.slice(rest, 0, max_chars),
      "truncated" => String.length(rest) > max_chars
    }
  end

  defp project(row),
    do: Map.take(row, ~w(id title workspaceRoot defaultModelSelection createdAt updatedAt))

  defp stream(thread_id), do: T3.Streams.Server.state(T3.Streams.ensure(thread_id))

  defp message_run(thread_id, message_id) do
    state = stream(thread_id)

    with %{"runId" => run_id} <- StreamState.get(state, "message")[message_id],
         do: StreamState.get(state, "run")[run_id],
         else: (_ -> nil)
  end

  # Waits for a run (the given one, or the latest) to finish, or for the timeout.
  defp wait(thread_id, run_id, timeout) do
    :ok = T3.Streams.subscribe(thread_id, self(), nil)
    deadline = System.monotonic_time(:millisecond) + timeout

    try do
      wait_loop(thread_id, run_id, deadline)
    after
      T3.Streams.Server.unsubscribe(thread_id, self())
    end
  end

  defp wait_loop(thread_id, run_id, deadline) do
    runs = StreamState.list(stream(thread_id), "run")

    run =
      if run_id,
        do: Enum.find(runs, &(&1["id"] == run_id)),
        else: Enum.max_by(runs, & &1["ordinal"], fn -> nil end)

    left = deadline - System.monotonic_time(:millisecond)

    cond do
      run == nil or run["status"] in @finished ->
        {run, false}

      left <= 0 ->
        {run, true}

      true ->
        receive do
          {:t3_stream, ^thread_id, _} -> wait_loop(thread_id, run_id, deadline)
        after
          min(left, 5_000) -> wait_loop(thread_id, run_id, deadline)
        end
    end
  end

  defp parse_number(value, _default) when is_number(value), do: round(value)
  defp parse_number(_value, default), do: default

  defp orchestration({:ok, _} = ok), do: ok

  defp orchestration({:error, message}) when is_binary(message),
    do: {:error, "orchestration_error", message}

  defp orchestration({:error, other}), do: {:error, "orchestration_error", inspect(other)}
end
