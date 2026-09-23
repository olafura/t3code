defmodule T3.Orchestration.Delegation do
  @moduledoc """
  Delegated tasks: child work a running thread hands to a subagent through MCP
  (`delegate_task`, `task_status`, `task_cancel`).

  A task is a new thread marked as a subagent of the caller, started with only the
  task prompt, on the caller's provider unless the task names another. The caller's
  thread records it as a `subagent` entity, node, and turn item, so the task shows
  in its timeline. When the child's run ends (`finished/3`), the entity takes the
  child's last answer, and the caller hears about it: an async task (`always`)
  sends the result as a message that runs once the caller is free, and a waiting
  one (`settled_only`) only when the caller's own run is already over.
  """

  alias T3.{Orchestration, StreamState}
  alias T3.Orchestration.Entities

  @active ~w(preparing starting running waiting)
  @terminal ~w(completed failed interrupted cancelled)
  @runtime_ranks %{
    "approval-required" => 0,
    "auto-accept-edits" => 1,
    "auto" => 2,
    "full-access" => 3
  }

  @doc "`delegate_task` for the caller thread `row` (a sidebar row) on provider `instance`."
  def delegate(row, instance, input) do
    parent = stream(row["id"])
    thread = StreamState.get(parent, "thread")[row["id"]]

    run =
      parent
      |> StreamState.list("run")
      |> Enum.filter(&(&1["status"] in @active))
      |> Enum.max_by(& &1["ordinal"], fn -> nil end)

    with :ok <- if(run && run["providerInstanceId"] == instance, do: :ok, else: not_active()),
         {:ok, selection} <- target(thread, input["target"]),
         {:ok, runtime} <- mode(thread["runtimeMode"], input["runtimeMode"], :runtime),
         {:ok, interaction} <-
           mode(thread["interactionMode"], input["interactionMode"], :interaction) do
      child_id = T3.Environment.uuid4()
      task_id = "node:subagent:" <> T3.Environment.uuid4()
      wake = if input["mode"] == "wait", do: "settled_only", else: "always"
      title = input["title"] || input["task"] |> String.split("\n") |> hd() |> String.slice(0, 80)

      {:ok, _} =
        Orchestration.launch_thread(%{
          "commandId" => "command:delegate:#{task_id}",
          "threadId" => child_id,
          "projectId" => thread["projectId"],
          "title" => title,
          "modelSelection" => selection,
          "runtimeMode" => runtime,
          "interactionMode" => interaction,
          "createdBy" => "agent",
          "creationSource" => "mcp",
          "workspaceStrategy" => workspace(thread),
          "lineage" => %{
            "parentThreadId" => thread["id"],
            "relationshipToParent" => "subagent",
            "rootThreadId" => get_in(thread, ["lineage", "rootThreadId"]) || thread["id"]
          },
          "initialMessage" => %{
            "messageId" => "message:delegate:" <> T3.Environment.uuid4(),
            "text" => input["task"],
            "attachments" => []
          }
        })

      record(thread, run, task_id, child_id, selection, title, input["task"], wake)

      if input["mode"] == "wait" do
        timeout = min(max(number(input["timeoutMs"], 600_000), 1), 3_600_000)
        wait(thread["id"], task_id, timeout)
      else
        {:ok, status(thread["id"], task_id)}
      end
    end
  end

  @doc "`task_status`: a task of the caller thread `thread_id`."
  def task_status(thread_id, task_id) do
    case status(thread_id, task_id) do
      nil -> {:error, "task_not_found", "The task was not found for this thread."}
      task -> {:ok, task}
    end
  end

  @doc "`task_cancel`: interrupts a running task; its result, if any, stays."
  def cancel(thread_id, task_id) do
    with %{} = task <-
           subagent(thread_id, task_id) ||
             {:error, "task_not_found", "The task was not found for this thread."},
         true <-
           task["status"] not in @terminal ||
             {:error, "task_not_cancellable", "The task has already finished."} do
      _ =
        Orchestration.dispatch(%{"type" => "run.interrupt", "threadId" => task["childThreadId"]})

      settle(thread_id, task, "cancelled", task["result"], "disposed")
      {:ok, status(thread_id, task_id)}
    end
  end

  @doc "Called when a run of `thread_id` ends: reports a subagent's result to its parent."
  def finished(thread_id, run_id, status) do
    child = stream(thread_id)

    with %{"lineage" => %{"relationshipToParent" => "subagent", "parentThreadId" => parent_id}} <-
           StreamState.get(child, "thread")[thread_id],
         %{} = task <-
           Enum.find(
             StreamState.list(stream(parent_id), "subagent"),
             &(&1["childThreadId"] == thread_id)
           ),
         true <- task["status"] not in @terminal do
      result = answer(child, run_id)

      delivery =
        if task["completionWake"] == "always" or idle?(parent_id),
          do: "delivered",
          else: "acknowledged"

      settle(parent_id, task, status, result, delivery)
      if delivery == "delivered", do: wake(parent_id, task, status, result)
    end

    :ok
  end

  # --- tasks -------------------------------------------------------------------------

  defp record(thread, run, task_id, child_id, selection, title, prompt, wake) do
    at = Entities.now()
    instance = selection["instanceId"]
    driver = Orchestration.driver_for(instance)
    item_id = "turn-item:subagent:#{task_id}"

    task = %{
      "id" => task_id,
      "threadId" => thread["id"],
      "runId" => run["id"],
      "parentNodeId" => run["rootNodeId"],
      "origin" => "app_owned",
      "createdBy" => "agent",
      "driver" => driver,
      "providerInstanceId" => instance,
      "providerThreadId" => nil,
      "childThreadId" => child_id,
      "nativeTaskRef" => nil,
      "prompt" => prompt,
      "title" => title,
      "model" => selection["model"],
      "completionWake" => wake,
      "completionDelivery" => %{"state" => "pending", "observedByRunId" => nil},
      "status" => "running",
      "result" => nil,
      "startedAt" => at,
      "completedAt" => nil,
      "updatedAt" => at
    }

    node = %{
      "id" => task_id,
      "threadId" => thread["id"],
      "runId" => run["id"],
      "parentNodeId" => run["rootNodeId"],
      "rootNodeId" => run["rootNodeId"],
      "kind" => "subagent",
      "status" => "running",
      "providerThreadId" => nil,
      "providerTurnId" => nil,
      "nativeItemRef" => nil,
      "runtimeRequestId" => nil,
      "checkpointScopeId" => nil,
      "countsForRun" => false,
      "startedAt" => at,
      "completedAt" => nil
    }

    T3.Streams.transact(thread["id"], :thread, fn state ->
      item =
        Entities.turn_item(
          %{
            thread: thread["id"],
            run: run["id"],
            root_node: run["rootNodeId"],
            node: task_id,
            provider_thread: nil,
            driver: driver
          },
          item_id,
          "subagent",
          Orchestration.next_ordinal(state),
          "running",
          at,
          %{
            "nodeId" => task_id,
            "subagentId" => task_id,
            "origin" => "app_owned",
            "driver" => driver,
            "providerInstanceId" => instance,
            "childThreadId" => child_id,
            "prompt" => prompt,
            "result" => nil
          }
        )

      {[
         Orchestration.create("subagent", task_id, task),
         Orchestration.create("node", task_id, node),
         Orchestration.create("turn-item", item_id, item)
       ], :ok}
    end)
  end

  defp settle(parent_id, task, status, result, delivery) do
    at = Entities.now()
    status = if status in @terminal, do: status, else: "completed"
    item_id = "turn-item:subagent:#{task["id"]}"

    T3.Streams.transact(parent_id, :thread, fn state ->
      finish = &Map.merge(&1, %{"status" => status, "completedAt" => at})

      changes =
        [
          Orchestration.upsert(state, "subagent", task["id"], fn entity ->
            Map.merge(entity, %{
              "status" => status,
              "result" => result,
              "completedAt" => at,
              "updatedAt" => at,
              "completionDelivery" => %{"state" => delivery, "observedByRunId" => nil}
            })
          end),
          Orchestration.upsert(state, "node", task["id"], finish),
          StreamState.get(state, "turn-item")[item_id] &&
            Orchestration.upsert(state, "turn-item", item_id, fn item ->
              Map.merge(item, %{
                "status" => status,
                "result" => result,
                "completedAt" => at,
                "updatedAt" => at
              })
            end)
        ]
        |> Enum.reject(&(&1 in [nil, false]))

      {changes, :ok}
    end)
  end

  # The parent hears the result as a message that runs once it is free.
  defp wake(parent_id, task, status, result) do
    text = """
    <delegated_task_result taskId="#{task["id"]}" title="#{task["title"]}" status="#{status}" childThreadId="#{task["childThreadId"]}">
    #{result || "(no answer)"}
    </delegated_task_result>
    """

    Orchestration.dispatch(%{
      "type" => "message.dispatch",
      "commandId" => "command:delegate-result:#{task["id"]}",
      "threadId" => parent_id,
      "messageId" => "message:delegate-result:" <> T3.Environment.uuid4(),
      "text" => String.trim(text),
      "attachments" => [],
      "createdBy" => "system",
      "creationSource" => "server",
      "dispatchMode" => %{"type" => "queue_after_active"}
    })
  end

  defp status(thread_id, task_id) do
    with %{} = task <- subagent(thread_id, task_id) do
      child = stream(task["childThreadId"])
      runs = StreamState.list(child, "run") |> Enum.sort_by(& &1["ordinal"])
      terminal = task["status"] in @terminal

      %{
        "taskId" => task["id"],
        "childThreadId" => task["childThreadId"],
        "childRunId" => runs |> List.first(%{}) |> Map.get("id"),
        "title" => task["title"],
        "providerInstanceId" => task["providerInstanceId"],
        "model" => task["model"],
        "status" => task["status"],
        "workState" => if(terminal, do: "result_available", else: "working"),
        "summary" => task["result"],
        "hasPendingChildRuns" =>
          Enum.any?(runs, &(&1["status"] in @active or &1["status"] == "queued")),
        "startedAt" => task["startedAt"],
        "completedAt" => task["completedAt"]
      }
    end
  end

  defp subagent(thread_id, task_id), do: StreamState.get(stream(thread_id), "subagent")[task_id]

  # Waits for the task to end; a timeout leaves it running and returns its state.
  defp wait(thread_id, task_id, timeout) do
    :ok = T3.Streams.subscribe(thread_id, self(), nil)
    deadline = System.monotonic_time(:millisecond) + timeout

    try do
      wait_loop(thread_id, task_id, deadline)
    after
      T3.Streams.Server.unsubscribe(thread_id, self())
    end
  end

  defp wait_loop(thread_id, task_id, deadline) do
    task = status(thread_id, task_id)
    left = deadline - System.monotonic_time(:millisecond)

    cond do
      task["status"] in @terminal ->
        {:ok, task}

      left <= 0 ->
        {:ok, Map.put(task, "waitTimedOut", true)}

      true ->
        receive do
          {:t3_stream, ^thread_id, _} -> wait_loop(thread_id, task_id, deadline)
        after
          min(left, 5_000) -> wait_loop(thread_id, task_id, deadline)
        end
    end
  end

  # The child's last answer in the run that ended.
  defp answer(child, run_id) do
    child
    |> StreamState.list("message")
    |> Enum.filter(&(&1["runId"] == run_id and &1["role"] == "assistant"))
    |> List.last(%{})
    |> Map.get("text")
  end

  defp idle?(thread_id),
    do: not Enum.any?(StreamState.list(stream(thread_id), "run"), &(&1["status"] in @active))

  defp target(thread, nil), do: {:ok, thread["modelSelection"]}

  defp target(thread, target) do
    instance = target["providerInstanceId"] || get_in(thread, ["modelSelection", "instanceId"])

    case Enum.find(T3.Environment.providers(), &(&1["instanceId"] == instance)) do
      nil ->
        {:error, "provider_unavailable", "Provider #{instance} is not available on this node."}

      provider ->
        model =
          target["model"] ||
            if(instance == get_in(thread, ["modelSelection", "instanceId"]),
              do: get_in(thread, ["modelSelection", "model"]),
              else: provider["models"] |> Enum.find(%{}, & &1["isDefault"]) |> Map.get("slug")
            )

        options =
          case target["options"] do
            %{} = map -> for {id, value} <- map, do: %{"id" => id, "value" => value}
            list when is_list(list) -> list
            _ -> nil
          end

        {:ok,
         %{"instanceId" => instance, "model" => model}
         |> then(&if(options, do: Map.put(&1, "options", options), else: &1))}
    end
  end

  defp mode(parent, requested, kind) when requested in [nil, "inherit"],
    do: mode(parent, parent, kind)

  defp mode(parent, requested, :runtime) do
    if Map.get(@runtime_ranks, requested, 3) > Map.get(@runtime_ranks, parent, 3),
      do:
        {:error, "runtime_mode_escalation_denied",
         "Child runtime mode #{requested} is broader than parent mode #{parent}."},
      else: {:ok, requested}
  end

  defp mode(parent, requested, :interaction) do
    if parent == "plan" and requested != "plan",
      do:
        {:error, "interaction_mode_escalation_denied",
         "Child interaction mode #{requested} is broader than parent mode plan."},
      else: {:ok, requested}
  end

  # The child works where the parent does.
  defp workspace(%{"worktreePath" => path, "branch" => branch}) when is_binary(path),
    do: %{"type" => "existing_worktree", "worktreePath" => path, "branch" => branch}

  defp workspace(_thread), do: %{"type" => "root"}

  defp not_active,
    do:
      {:error, "parent_not_active",
       "Delegated tasks require an active run owned by this MCP provider session."}

  defp stream(thread_id), do: T3.Streams.Server.state(T3.Streams.ensure(thread_id))

  defp number(value, _default) when is_number(value), do: round(value)
  defp number(_value, default), do: default
end
