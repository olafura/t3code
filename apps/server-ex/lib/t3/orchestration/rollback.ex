defmodule T3.Orchestration.Rollback do
  @moduledoc """
  `checkpoint.rollback`: rewinds a thread to one of its checkpoints. The provider
  drops the later turns from its conversation, the worktree goes back to the
  checkpoint unless `restoreFiles` is false, and the later runs become
  `rolled_back`, which hides them from the timeline.

  Restoring files resets the whole checkout, so it needs a worktree only this
  thread uses.
  """

  alias T3.Orchestration
  alias T3.Orchestration.Entities
  alias T3.StreamState

  @shared_workspace "File restore requires an isolated worktree. This workspace may contain changes from another thread. Rewind the conversation without restoring files instead."
  @active ~w(preparing starting running waiting)
  @finished ~w(completed failed interrupted)

  @spec run(map) :: :ok | {:error, String.t()}
  def run(%{"threadId" => thread_id} = command) do
    with {:ok, plan} <- T3.Streams.transact(thread_id, :thread, &{[], plan(&1, command)}),
         {:ok, patch} <- rewind(plan),
         :ok <- restore(plan),
         :ok <- T3.Streams.transact(thread_id, :thread, &{settle(&1, plan, patch), :ok}) do
      T3.Vcs.Watch.refresh(plan.cwd)
      T3.Workspace.invalidate(plan.cwd)
      :ok
    end
  end

  defp plan(state, command) do
    thread = StreamState.get(state, "thread")[command["threadId"]]
    runs = StreamState.list(state, "run")
    checkpoint = StreamState.get(state, "checkpoint")[command["checkpointId"]]
    scope = checkpoint && StreamState.get(state, "checkpoint-scope")[checkpoint["scopeId"]]

    provider_thread =
      thread && StreamState.get(state, "provider-thread")[thread["activeProviderThreadId"]]

    restore = command["restoreFiles"] != false

    cond do
      thread == nil ->
        {:error, "Thread #{command["threadId"]} was not found."}

      Enum.any?(runs, &(&1["status"] in @active)) ->
        {:error, "Interrupt the current turn before rewinding."}

      checkpoint == nil or checkpoint["status"] != "ready" ->
        {:error, "Checkpoint #{command["checkpointId"]} cannot be restored."}

      scope == nil or scope["id"] != command["scopeId"] ->
        {:error, "Checkpoint #{command["checkpointId"]} is not in scope #{command["scopeId"]}."}

      provider_thread == nil ->
        {:error, "No active provider thread exists for rollback."}

      restore and not isolated?(thread, scope) ->
        {:error, @shared_workspace}

      true ->
        target = checkpoint["appRunOrdinal"] || 0
        later = Enum.filter(runs, &(&1["ordinal"] > target and &1["status"] in @finished))
        ordinals = MapSet.new(later, & &1["ordinal"])

        # A provider turn carries its run's ordinal.
        turns =
          state
          |> StreamState.list("provider-turn")
          |> Enum.filter(&(&1["providerThreadId"] == provider_thread["id"]))

        dropped = Enum.filter(turns, &MapSet.member?(ordinals, &1["ordinal"]))

        head =
          Enum.find_value(turns, fn turn ->
            if turn["ordinal"] == target and target > 0,
              do: get_in(turn, ["nativeTurnRef", "nativeId"])
          end)

        {:ok,
         %{
           thread_id: thread["id"],
           instance: provider_thread["providerInstanceId"],
           driver: provider_thread["driver"],
           provider_thread: provider_thread,
           native_thread_id: get_in(provider_thread, ["nativeThreadRef", "nativeId"]),
           model: get_in(thread, ["modelSelection", "model"]),
           cwd: scope["cwd"],
           target: target,
           runs: later,
           drop: Enum.count(dropped),
           first_dropped:
             dropped
             |> Enum.min_by(& &1["ordinal"], fn -> %{} end)
             |> get_in(["nativeTurnRef", "nativeId"]),
           head: head,
           checkpoint: checkpoint,
           restore: restore,
           stale:
             state
             |> StreamState.list("checkpoint")
             |> Enum.filter(
               &(&1["scopeId"] == scope["id"] and &1["status"] == "ready" and
                   (&1["appRunOrdinal"] || 0) > target)
             )
         }}
    end
  end

  # Nothing to drop from the conversation when every later run is already gone.
  defp rewind(%{drop: 0}), do: {:ok, %{}}

  defp rewind(%{driver: "claudeAgent", target: target, head: nil}) when target > 0,
    do: {:error, "Cannot rewind this Claude thread: no message was recorded for that turn."}

  defp rewind(plan), do: Orchestration.runtime(plan.instance).rollback(plan.thread_id, plan)

  defp restore(plan) do
    result =
      if plan.restore, do: T3.Checkpoint.restore(plan.cwd, plan.checkpoint["ref"]), else: :ok

    with :ok <- result do
      for checkpoint <- plan.stale, do: T3.Checkpoint.delete_ref(plan.cwd, checkpoint["ref"])
      :ok
    else
      {:error, {_status, detail}} -> {:error, "Could not restore the checkpoint: #{detail}"}
      {:error, reason} -> {:error, "Could not restore the checkpoint: #{inspect(reason)}"}
    end
  end

  defp settle(state, plan, patch) do
    at = Entities.now()

    provider_thread =
      Orchestration.upsert(state, "provider-thread", plan.provider_thread["id"], fn entity ->
        entity
        |> Map.merge(patch)
        |> Map.merge(%{
          "lastRunOrdinal" => if(plan.target > 0, do: plan.target),
          "status" => "idle",
          "updatedAt" => at
        })
      end)

    stale =
      for checkpoint <- plan.stale,
          do:
            Orchestration.upsert(
              state,
              "checkpoint",
              checkpoint["id"],
              &Map.put(&1, "status", "stale")
            )

    rolled_back = &Map.merge(&1, %{"status" => "rolled_back", "completedAt" => at})

    runs =
      Enum.flat_map(plan.runs, fn run ->
        [
          Orchestration.upsert(state, "run", run["id"], rolled_back),
          run["rootNodeId"] && Orchestration.upsert(state, "node", run["rootNodeId"], rolled_back)
        ]
      end)

    # An upsert that changes nothing is nil.
    Enum.reject([provider_thread | stale ++ runs], &is_nil/1)
  end

  # The thread's own worktree, which no other thread on this node points at.
  defp isolated?(thread, scope) do
    worktree = thread["worktreePath"]

    worktree != nil and real(scope["cwd"]) == real(worktree) and
      not Enum.any?(T3.Shell.rows(), fn
        {{node, id}, {"thread", row}} ->
          node == node() and id != thread["id"] and row["deletedAt"] == nil and
            row["worktreePath"] != nil and real(row["worktreePath"]) == real(worktree)

        _ ->
          false
      end)
  end

  # The path with its symlinks resolved (macOS temp paths go through /var -> /private/var).
  defp real(path) do
    path
    |> Path.expand()
    |> Path.split()
    |> Enum.reduce("/", fn part, dir ->
      next = Path.join(dir, part)

      case :file.read_link_all(next) do
        {:ok, target} -> Path.expand(to_string(target), dir)
        _ -> next
      end
    end)
  end
end
