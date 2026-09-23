defmodule T3.Projection.Shell do
  @moduledoc """
  A thread's sidebar row, ported from the Node server's `threadShellFromProjection`.

  `thread_shell/2` returns the row exactly as the Node server sends it: a JSON-shaped
  map with string keys and `nil` for null, dates as the ISO strings the entities
  carry, and `updatedAt` from the time of the stream's latest event.

  A thread forked from a run counts the source's history in `visibleItemCount`. Pass
  the source thread's state, or a function resolving any thread id to its state for
  forks of forks; without it the count covers the thread's own items only.
  """

  import T3.Projection.JS, only: [get: 2, json: 1, epoch_ms: 1, iso: 1]

  alias T3.Projection.{BackgroundWork, PullRequests, ThreadError, Timeline}
  alias T3.StreamState

  @interruptible ~w(preparing starting running)

  # Absent from older payloads; the Node schema omits them rather than sending null.
  @optional_fields ~w(linkedPullRequest branchPullRequest activeOrderKey historyOrigin)

  @spec thread_shell(StreamState.t(), StreamState.t() | Timeline.resolve() | nil) :: map
  def thread_shell(%StreamState{} = state, source \\ nil) do
    thread = Timeline.thread(state)
    runs = StreamState.list(state, "run")
    turn_items = StreamState.list(state, "turn-item")
    provider_threads = StreamState.list(state, "provider-thread")
    latest_run = List.last(runs)
    active_run = runs |> Enum.filter(&interruptible?/1) |> latest_by(&get(&1, "ordinal"))

    activity_run =
      runs
      |> Enum.filter(&(interruptible?(&1) or get(&1, "status") == "waiting"))
      |> latest_by(&get(&1, "ordinal"))

    pending_request =
      state
      |> StreamState.list("runtime-request")
      |> Enum.filter(&(get(&1, "status") == "pending"))
      |> latest_by(&epoch_ms(get(&1, "createdAt")))

    latest_user_message =
      state
      |> StreamState.list("message")
      |> Enum.filter(&(get(&1, "role") == "user"))
      |> latest_by(&epoch_ms(get(&1, "updatedAt")))

    provider_session =
      state
      |> StreamState.list("provider-session")
      |> Enum.filter(&(get(&1, "providerInstanceId") == get(thread, "providerInstanceId")))
      |> latest_by(&epoch_ms(get(&1, "updatedAt")))

    local_items = Timeline.local_items(state)

    visible_count =
      if source,
        do: length(Timeline.visible_items(state, resolver(source))),
        else: length(local_items)

    error =
      ThreadError.summary(
        ThreadError.latest_root_provider_failure(latest_run, turn_items),
        get(provider_session, "lastError")
      )

    thread
    |> Map.take(@optional_fields)
    |> json()
    |> Map.merge(error)
    |> Map.merge(%{
      "createdBy" => get(thread, "createdBy"),
      "creationSource" => get(thread, "creationSource"),
      "id" => get(thread, "id"),
      "projectId" => get(thread, "projectId"),
      "title" => get(thread, "title"),
      "providerInstanceId" => get(thread, "providerInstanceId"),
      "modelSelection" => model_selection(get(thread, "modelSelection")),
      "runtimeMode" => get(thread, "runtimeMode"),
      "interactionMode" => get(thread, "interactionMode"),
      "branch" => get(thread, "branch"),
      "worktreePath" => get(thread, "worktreePath"),
      "pullRequests" => PullRequests.of(thread),
      "lineage" => json(get(thread, "lineage")),
      "forkedFrom" => json(get(thread, "forkedFrom")),
      "activeProviderThreadId" => get(thread, "activeProviderThreadId"),
      "latestRunId" => get(latest_run, "id"),
      "latestRunRequestedAt" => get(latest_run, "requestedAt"),
      "latestRunStartedAt" => get(latest_run, "startedAt"),
      "latestRunCompletedAt" => get(latest_run, "completedAt"),
      "activeRunId" => get(active_run, "id"),
      "activityRunStatus" => get(activity_run, "status"),
      "activityRunStartedAt" =>
        get(activity_run, "startedAt") || get(activity_run, "requestedAt"),
      "status" => get(latest_run, "status") || "idle",
      "pendingRuntimeRequest" =>
        pending_request &&
          %{
            "id" => get(pending_request, "id"),
            "kind" => get(pending_request, "kind"),
            "createdAt" => get(pending_request, "createdAt")
          },
      # Thread detail owns message bodies; shell rows stay independent of transcript size.
      "latestVisibleMessage" => nil,
      "latestUserMessageAt" => get(latest_user_message, "updatedAt"),
      "hasActionableProposedPlan" =>
        state
        |> StreamState.list("plan")
        |> Enum.any?(&(get(&1, "kind") == "proposed_plan" and get(&1, "status") == "active")),
      "pendingBackgroundTasks" =>
        BackgroundWork.derive(
          latest_run: latest_run,
          provider_threads: provider_threads,
          turn_items: turn_items,
          active_provider_thread_id: get(thread, "activeProviderThreadId"),
          runs: runs
        ),
      "providerInstanceHistory" => provider_instance_history(get(thread, "id"), provider_threads),
      "itemCount" => length(local_items),
      "visibleItemCount" => visible_count,
      "createdAt" => get(thread, "createdAt"),
      "updatedAt" =>
        if(state.updated_at, do: iso(state.updated_at), else: get(thread, "updatedAt")),
      "archivedAt" => get(thread, "archivedAt"),
      "settledOverride" => get(thread, "settledOverride"),
      "settledAt" => get(thread, "settledAt"),
      "unsettledAt" => get(thread, "unsettledAt"),
      "snoozedUntil" => get(thread, "snoozedUntil"),
      "snoozedAt" => get(thread, "snoozedAt"),
      "pinnedAt" => get(thread, "pinnedAt"),
      "pinOrderKey" => get(thread, "pinOrderKey"),
      "lastVisitedAt" => get(thread, "lastVisitedAt"),
      "titleRegeneration" => json(get(thread, "titleRegeneration")),
      "limitRecovery" => json(get(thread, "limitRecovery")),
      "deletedAt" => get(thread, "deletedAt")
    })
  end

  @doc """
  Provider instances that have owned the thread's root conversation, oldest first.
  Subagent provider threads have an owner node and are left out, so a delegated child
  on another provider does not make the thread look handed off.
  """
  @spec provider_instance_history(String.t(), [map]) :: [String.t()]
  def provider_instance_history(thread_id, provider_threads) do
    provider_threads
    |> Enum.filter(&(get(&1, "appThreadId") == thread_id and get(&1, "ownerNodeId") == nil))
    |> Enum.sort_by(&{epoch_ms(get(&1, "createdAt")), get(&1, "id")})
    |> Enum.map(&get(&1, "providerInstanceId"))
    |> Enum.uniq()
  end

  defp interruptible?(run), do: get(run, "status") in @interruptible

  # The first element with the greatest key, as a stable descending sort's head.
  defp latest_by([], _key), do: nil
  defp latest_by(list, key), do: Enum.max_by(list, key)

  # Legacy selections named the provider instead of the instance.
  defp model_selection(nil), do: nil

  defp model_selection(selection) do
    instance_id =
      case Map.fetch(selection, "instanceId") do
        {:ok, id} -> id
        :error -> if is_binary(selection["provider"]), do: selection["provider"]
      end

    %{"instanceId" => instance_id, "model" => selection["model"]}
    |> Map.merge(Map.take(selection, ["options"]))
    |> json()
  end

  defp resolver(%StreamState{} = source) do
    source_id = get(Timeline.thread(source), "id")
    fn thread_id -> if thread_id == source_id, do: source end
  end

  defp resolver(resolve) when is_function(resolve, 1), do: resolve
end
