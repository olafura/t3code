defmodule T3.Orchestration.Settlement do
  @moduledoc """
  Settles threads that need nobody any more (`thread.auto-settle`), as the Node
  server's `ThreadSettlementService` does: one whose pull requests all merged
  (`sidebarAutoSettleOnMerge`) or closed after the user last spoke in it, or one idle
  for `sidebarAutoSettleAfterDays`, each resolved per project override. Pinned,
  running, waiting-on-you, just-messaged and still-snoozed threads are left alone,
  and the thread is checked again as it settles, so anything newer wins.

  Linked pull requests decide from their synced snapshots (`T3.PullRequests.Sync`); a
  thread with none uses its branch's (`T3.PullRequests.Discovery`), read in one batch
  per host. Threads are swept every minute, when the settlement settings change, and
  one at a time when a run ends or their pull requests change. `sweep/0` runs a sweep
  now and returns when it is done.
  """

  use GenServer

  require Logger

  import T3.Projection.JS, only: [epoch_ms: 1, iso: 1]

  alias T3.Projection.PullRequests, as: Links

  @interval 60_000
  @day 24 * 60 * 60 * 1_000
  @queued_turn_grace 2 * 60 * 1_000
  @default_after_days 3

  @doc "Options: `interval`, the sweep period in ms, or nil for no timer and no first sweep."
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Sweeps every thread now."
  def sweep, do: GenServer.call(__MODULE__, :sweep, :infinity)

  @impl true
  def init(opts) do
    :ok = T3.Shell.subscribe(self())
    :ok = T3.Settings.watch(self())
    interval = Keyword.get(opts, :interval, @interval)
    if interval, do: send(self(), :tick)

    {:ok,
     %{
       interval: interval,
       settings: settings_key(T3.Settings.settings()),
       seen: Map.new(threads(), &{&1["id"], watched(&1)}),
       pending: MapSet.new()
     }}
  end

  @impl true
  def handle_call(:sweep, _from, state), do: {:reply, :ok, sweep(state, nil)}

  @impl true
  def handle_info(:tick, state) do
    state = sweep(state, nil)
    Process.send_after(self(), :tick, state.interval)
    {:noreply, state}
  end

  def handle_info(:run, state),
    do: {:noreply, sweep(%{state | pending: MapSet.new()}, state.pending)}

  def handle_info({:t3_settings, _node, settings}, state) do
    case settings_key(settings) do
      same when same == state.settings -> {:noreply, state}
      key -> {:noreply, sweep(%{state | settings: key}, nil)}
    end
  end

  def handle_info({:t3_shell, {:rows, node, rows}}, state) when node == node() do
    {seen, changed} =
      for {id, {"thread", row}} <- rows, reduce: {state.seen, []} do
        {seen, changed} ->
          now = watched(row)
          if seen[id] == now, do: {seen, changed}, else: {Map.put(seen, id, now), [id | changed]}
      end

    if changed != [] and MapSet.size(state.pending) == 0, do: send(self(), :run)
    {:noreply, %{state | seen: seen, pending: MapSet.union(state.pending, MapSet.new(changed))}}
  end

  def handle_info(_other, state), do: {:noreply, state}

  # What can make a thread settle: its runs, what it waits on, and its pull requests.
  defp watched(row),
    do:
      {row["status"], row["activityRunStatus"], row["pendingRuntimeRequest"],
       row["branchPullRequest"],
       for(
         link <- row["pullRequests"] || [],
         do: {link["number"], link["source"], link["snapshot"]["state"]}
       )}

  defp threads do
    for {{node, _}, {"thread", row}} <- T3.Shell.rows(),
        node == node() and row["deletedAt"] == nil,
        do: row
  end

  # `only` is nil for every thread, else a set of thread ids.
  defp sweep(state, only) do
    settings = T3.Settings.settings()

    if configured?(settings) do
      now = System.system_time(:millisecond)

      candidates =
        for row <- threads(),
            only == nil or MapSet.member?(only, row["id"]),
            candidate?(row, now),
            do: row

      # Inactivity and synced links need no host; only threads with neither are looked up.
      lookups =
        for row <- candidates,
            not settle(row, nil, settings, now),
            Links.visible(row["pullRequests"] || []) == [],
            reference = row["linkedPullRequest"] || row["branchPullRequest"],
            do: {row, reference |> Links.legacy_key() |> Map.take(~w(host repository number))}

      summaries =
        if lookups == [],
          do: %{},
          else: T3.PullRequests.summaries(lookups |> Enum.map(&elem(&1, 1)) |> Enum.uniq())

      for {row, ref} <- lookups, summary = summaries[ref] do
        settle(row, Map.take(summary, ~w(state mergedAt closedAt)), settings, now)
      end
    end

    state
  rescue
    error ->
      Logger.warning("automatic thread settlement sweep failed: #{Exception.message(error)}")
      state
  end

  defp settle(row, pull_request, settings, now) do
    {on_merge, after_days} = resolved(settings, row["projectId"])

    case settled_at(row, pull_request, now, after_days, on_merge) do
      nil ->
        false

      settled_at ->
        command = %{
          "type" => "thread.auto-settle",
          "commandId" => "server:auto-settle:#{row["id"]}:#{T3.Environment.uuid4()}",
          "threadId" => row["id"],
          "snapshotAt" => row["updatedAt"],
          "settledAt" => settled_at
        }

        case T3.Orchestration.dispatch(command) do
          {:ok, _} ->
            true

          {:error, reason} ->
            Logger.info("automatic settlement skipped for #{row["id"]}: #{inspect(reason)}")
            true
        end
    end
  end

  @doc """
  When a thread settles, as an ISO time, or nil (`resolveAutoSettlementAt`).
  `pull_request` (`%{"state", "mergedAt", "closedAt"}`) stands in for a thread
  without visible links; linked threads decide from their snapshots.
  """
  def settled_at(row, pull_request, now, after_days, on_merge) do
    links = Links.visible(row["pullRequests"] || [])

    if Enum.any?(links, &(&1["snapshot"] == nil or &1["snapshot"]["state"] == "open")) do
      nil
    else
      pull_request =
        if links == [],
          do: pull_request,
          else:
            links
            |> Enum.reduce(&if(terminal_at(&1) > terminal_at(&2), do: &1, else: &2))
            |> Map.get("snapshot")

      activity =
        latest(
          ~w(latestUserMessageAt latestRunRequestedAt latestRunStartedAt latestRunCompletedAt),
          row
        )

      cond do
        not candidate?(row, now) ->
          nil

        pull_request && settles?(row, pull_request, on_merge) ->
          (activity && iso(activity)) || row["createdAt"]

        after_days == nil or activity == nil ->
          nil

        activity < now - after_days * @day ->
          iso(activity)

        true ->
          nil
      end
    end
  end

  # A link's merge or close time; one without sorts first.
  defp terminal_at(link) do
    snapshot = link["snapshot"] || %{}
    at = if snapshot["state"] == "merged", do: snapshot["mergedAt"], else: snapshot["closedAt"]
    epoch_ms(at) || -1
  end

  defp settles?(row, pull_request, on_merge) do
    state = pull_request["state"]
    at = if state == "merged", do: pull_request["mergedAt"], else: pull_request["closedAt"]
    anchor = latest(~w(createdAt latestUserMessageAt latestRunRequestedAt), row)
    closed_at = epoch_ms(at)

    (state == "closed" or (state == "merged" and on_merge)) and closed_at != nil and
      anchor != nil and closed_at >= anchor
  end

  @doc "Whether a thread may settle at all (`isAutoSettlementCandidate`)."
  def candidate?(row, now) do
    row["archivedAt"] == nil and row["settledOverride"] == nil and row["pinnedAt"] == nil and
      row["pendingRuntimeRequest"] == nil and row["activityRunStatus"] == nil and
      (row["pendingBackgroundTasks"] || []) == [] and not queued_turn_start?(row, now) and
      awake?(row, now)
  end

  # A snoozed thread that woke early, on an error or finished work, may settle; one
  # still parked until its wake time may not.
  defp awake?(row, now) do
    until = epoch_ms(row["snoozedUntil"])
    snoozed_at = epoch_ms(row["snoozedAt"])
    completed = epoch_ms(row["latestRunCompletedAt"])
    woke_after_snooze? = snoozed_at != nil and completed != nil and completed > snoozed_at

    until == nil or until <= now or woke_after_snooze? or
      (row["status"] == "failed" and snoozed_at == nil)
  end

  # A just-sent message waits a moment for the run that takes it.
  defp queued_turn_start?(row, now) do
    message = epoch_ms(row["latestUserMessageAt"])

    cond do
      message == nil or row["status"] == "failed" ->
        false

      abs(now - message) > @queued_turn_grace ->
        false

      row["latestRunId"] == nil ->
        true

      true ->
        ~w(latestRunRequestedAt latestRunStartedAt latestRunCompletedAt)
        |> Enum.map(&epoch_ms(row[&1]))
        |> Enum.all?(&(&1 == nil or &1 < message))
    end
  end

  defp latest(fields, row) do
    case for(field <- fields, ms = epoch_ms(row[field]), do: ms) do
      [] -> nil
      times -> Enum.max(times)
    end
  end

  # `{on merge?, after days or nil}` for a project, its overrides winning when set.
  defp resolved(settings, project_id) do
    override = get_in(settings, ["projectSettingsOverrides", project_id]) || %{}

    on_merge =
      Map.get(
        override,
        "sidebarAutoSettleOnMerge",
        Map.get(settings, "sidebarAutoSettleOnMerge", true)
      )

    after_days =
      Map.get(
        override,
        "sidebarAutoSettleAfterDays",
        Map.get(settings, "sidebarAutoSettleAfterDays", @default_after_days)
      )

    {on_merge != false, after_days}
  end

  defp configured?(settings) do
    {on_merge, after_days} = resolved(settings, nil)

    on_merge or after_days != nil or
      Enum.any?(Map.values(settings["projectSettingsOverrides"] || %{}), fn entry ->
        entry["sidebarAutoSettleOnMerge"] == true or entry["sidebarAutoSettleAfterDays"] != nil
      end)
  end

  # Everything settlement reads from the settings, so other edits do not start a sweep.
  defp settings_key(settings) do
    overrides =
      for {project, entry} <- settings["projectSettingsOverrides"] || %{},
          touched = Map.take(entry, ~w(sidebarAutoSettleOnMerge sidebarAutoSettleAfterDays)),
          touched != %{},
          do: {project, touched}

    {settings["sidebarAutoSettleOnMerge"], settings["sidebarAutoSettleAfterDays"],
     Enum.sort(overrides)}
  end
end
