defmodule T3.PullRequests.Discovery do
  @moduledoc """
  Finds the pull request each thread's branch opened and keeps the thread's
  `branchPullRequest` on it (`thread.pull-request.sync`), as the Node server's
  `ThreadPullRequestService` does. A thread whose only link is a legacy
  `linkedPullRequest` that merged or closed moves to its branch's open one.

  A thread is looked at when it appears, changes branch, worktree or title, or is
  unarchived, and with a fresh answer when it is unsettled or a run ends. Unsettled
  threads are swept every minute; at start, settled threads that never found theirs
  get a few sweeps to. Only GitHub checkouts are asked, through `gh`. A branch's
  answer is believed for a minute while its pull request is open and five otherwise,
  and failures back off. `sweep/0` runs a sweep now and returns when it is done.
  """

  use GenServer

  require Logger

  alias T3.Orchestration
  alias T3.Projection.PullRequests, as: Links
  alias T3.PullRequests.GitHub

  @interval 60_000
  @backfill_attempts 5
  @open_ttl 60_000
  @quiet_ttl 5 * 60_000
  @failure_ttl 20_000
  @failure_max_ttl 15 * 60_000
  @watched ~w(branch worktreePath title archivedAt settledOverride latestRunCompletedAt)

  @doc "Options: `interval`, the sweep period in ms, or nil for no timer and no first sweep."
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Sweeps every unsettled thread now."
  def sweep, do: GenServer.call(__MODULE__, :sweep, :infinity)

  @impl true
  def init(opts) do
    :ok = T3.Shell.subscribe(self())
    interval = Keyword.get(opts, :interval, @interval)
    if interval, do: send(self(), :backfill)

    {:ok,
     %{
       interval: interval,
       seen: Map.new(threads(), &{&1["id"], Map.take(&1, @watched)}),
       pending: %{},
       backfill: %{},
       lookups: %{}
     }}
  end

  @impl true
  def handle_call(:sweep, _from, state), do: {:reply, :ok, synchronize(state, nil, false)}

  @impl true
  def handle_info(:backfill, state), do: {:noreply, state |> synchronize(nil, true) |> tick()}
  def handle_info(:tick, state), do: {:noreply, state |> synchronize(nil, false) |> tick()}

  def handle_info(:run, state),
    do: {:noreply, synchronize(%{state | pending: %{}}, state.pending, false)}

  def handle_info({:t3_shell, {:rows, node, rows}}, state) when node == node() do
    {seen, pending} =
      for {id, {"thread", row}} <- rows, reduce: {state.seen, state.pending} do
        {seen, pending} ->
          now = Map.take(row, @watched)
          seen = Map.put(seen, id, now)

          case trigger(state.seen[id], now) do
            nil -> {seen, pending}
            fresh? -> {seen, Map.update(pending, id, fresh?, &(&1 or fresh?))}
          end
      end

    if state.pending == %{} and pending != %{}, do: send(self(), :run)
    {:noreply, %{state | seen: seen, pending: pending}}
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp tick(state) do
    Process.send_after(self(), :tick, state.interval)
    state
  end

  # nil when the change says nothing about the branch, else whether to ask fresh.
  defp trigger(nil, _now), do: false

  defp trigger(before, now) do
    cond do
      (now["settledOverride"] == "active" and before["settledOverride"] != "active") or
          now["latestRunCompletedAt"] != before["latestRunCompletedAt"] ->
        true

      Map.take(now, ~w(branch worktreePath title)) !=
        Map.take(before, ~w(branch worktreePath title)) or
          (before["archivedAt"] != nil and now["archivedAt"] == nil) ->
        false

      true ->
        nil
    end
  end

  defp threads do
    for {{node, _}, {"thread", row}} <- T3.Shell.rows(),
        node == node() and row["deletedAt"] == nil,
        do: row
  end

  defp settled?(row), do: row["settledOverride"] == "settled" or row["settledAt"] != nil

  # `targets` is nil for every unsettled thread, else `%{thread_id => fresh?}`.
  defp synchronize(state, targets, backfill?) do
    rows = threads()

    backfill =
      if backfill?,
        do:
          Map.merge(
            state.backfill,
            for(
              row <- rows,
              settled?(row) and row["branchPullRequest"] == nil,
              into: %{},
              do: {row["id"], @backfill_attempts}
            )
          ),
        else: state.backfill

    state = %{state | backfill: Map.take(backfill, Enum.map(rows, & &1["id"]))}

    rows
    |> Enum.filter(fn row ->
      row["archivedAt"] == nil and (targets == nil or Map.has_key?(targets, row["id"])) and
        (not settled?(row) or targets != nil or Map.has_key?(state.backfill, row["id"])) and
        (row["branch"] != nil or row["branchPullRequest"] != nil)
    end)
    |> Enum.group_by(&{&1["projectId"], &1["worktreePath"], &1["branch"]})
    |> Map.values()
    |> Enum.map(fn group -> {group, targets != nil and Enum.any?(group, &targets[&1["id"]])} end)
    |> discover(state)
  rescue
    error ->
      Logger.warning("thread pull request discovery failed: #{Exception.message(error)}")
      state
  end

  defp discover(groups, state) do
    now = System.monotonic_time(:millisecond)

    # A failure is kept past its wait so the next one waits longer, until a long quiet.
    lookups =
      Map.reject(state.lookups, fn {_, e} ->
        e.expires + if(e.answer == :error, do: @failure_max_ttl, else: 0) <= now
      end)

    state = %{state | lookups: lookups}

    {placed, state} =
      Enum.flat_map_reduce(groups, state, fn {[first | _] = group, fresh?}, state ->
        with %{"workspaceRoot" => root} = project <- project(first["projectId"]),
             remote = remote(root),
             true <- first["branch"] == nil or (remote != nil and remote.kind == "github") do
          worktree = first["worktreePath"]
          cwd = if worktree && File.dir?(worktree), do: worktree, else: root

          {[%{group: group, project: project, remote: remote, cwd: cwd, fresh?: fresh?}], state}
        else
          _ -> {[], Enum.reduce(group, state, &finish(&2, &1))}
        end
      end)

    # A fresh answer replaces a cached one, but a failing branch keeps backing off.
    wanted =
      for %{group: [%{"branch" => branch} | _]} = p <- placed,
          branch != nil,
          (case state.lookups[{p.cwd, branch}] do
             nil -> true
             %{answer: :error} = failed -> failed.expires <= now
             _ -> p.fresh?
           end),
          uniq: true,
          do: {p.cwd, branch}

    state = fetch(state, wanted)

    placed =
      Enum.map(placed, fn p ->
        fetched? = {p.cwd, hd(p.group)["branch"]} in wanted
        Map.merge(p, %{detected: detected(state, p), fetched?: fetched?})
      end)

    summaries = previous_summaries(placed)
    Enum.reduce(placed, state, &plan(&1, &2, summaries))
  end

  # Asks `gh` about each wanted branch, a few at a time, and remembers the answers.
  defp fetch(state, wanted) do
    wanted
    |> Task.async_stream(
      fn {cwd, branch} -> {{cwd, branch}, GitHub.branch_pull_request(cwd, branch)} end,
      max_concurrency: 8,
      timeout: :infinity
    )
    |> Enum.reduce(state, fn {:ok, {key, answer}}, state ->
      now = System.monotonic_time(:millisecond)

      entry =
        case answer do
          {:ok, pr} ->
            ttl = if pr && pr["state"] == "open", do: @open_ttl, else: @quiet_ttl
            %{answer: pr, failures: 0, expires: now + ttl}

          {:error, _} ->
            failures = ((state.lookups[key] || %{})[:failures] || 0) + 1
            ttl = min(@failure_ttl * Integer.pow(2, failures - 1), @failure_max_ttl)
            %{answer: :error, failures: failures, expires: now + ttl}
        end

      %{state | lookups: Map.put(state.lookups, key, entry)}
    end)
  end

  # `{:ok, pull request or nil}` when the branch's answer belongs to the project's own
  # repository, `:mismatch` when it does not, `:error` when there is none. A default
  # branch counts only while its pull request is open: merged ones there are reverse
  # merges.
  defp detected(_state, %{group: [%{"branch" => nil} | _]}), do: {:ok, nil}

  defp detected(state, %{group: [%{"branch" => branch} | _]} = p) do
    case state.lookups[{p.cwd, branch}] do
      %{answer: %{} = pr} ->
        parsed = Links.parse_change_request_url(pr["url"])

        cond do
          parsed == nil or parsed.host != p.remote.host or
              parsed.repository != String.downcase(p.remote.repository) ->
            :mismatch

          pr["state"] != "open" and default_branch?(p.cwd, branch) ->
            {:ok, nil}

          true ->
            {:ok,
             %{
               "projectId" => p.project["id"],
               "repository" => p.remote.repository,
               "number" => pr["number"],
               "url" => pr["url"],
               "state" => pr["state"]
             }}
        end

      %{answer: nil} ->
        {:ok, nil}

      _ ->
        :error
    end
  end

  defp default_branch?(cwd, branch) do
    case T3.Git.ok(cwd, ~w(symbolic-ref --short refs/remotes/origin/HEAD)) do
      {:ok, ref} -> branch == ref |> String.trim() |> String.replace_prefix("origin/", "")
      _ -> branch in ["main", "master"]
    end
  end

  # What a thread in a group would move off, and so needs the host's word on: a
  # branch pull request its branch no longer finds, and a legacy link an open branch
  # pull request would replace. One batch per host.
  defp previous_summaries(placed) do
    refs =
      for %{detected: {:ok, found}} = p <- placed,
          row <- p.group,
          previous <- [kept_candidate(row, found), replaced_candidate(row, found)],
          previous != nil,
          uniq: true,
          do: summary_ref(previous)

    if refs == [], do: %{}, else: T3.PullRequests.summaries(refs)
  end

  defp kept_candidate(row, nil) do
    if row["branch"] != nil and row["worktreePath"] == nil, do: row["branchPullRequest"]
  end

  defp kept_candidate(_row, _found), do: nil

  defp replaced_candidate(row, %{"state" => "open"} = found) do
    if (row["pullRequests"] || []) == [] and row["linkedPullRequest"] != nil and
         not same?(row["linkedPullRequest"], reference(found)),
       do: row["linkedPullRequest"]
  end

  defp replaced_candidate(_row, _found), do: nil

  defp summary_ref(linked),
    do: linked |> Links.legacy_key() |> Map.take(~w(host repository number))

  defp terminal?(summaries, linked),
    do: linked != nil and summaries[summary_ref(linked)]["state"] in ["merged", "closed"]

  defp reference(nil), do: nil
  defp reference(found), do: Map.delete(found, "state")

  defp plan(%{detected: :error} = p, state, _), do: Enum.reduce(p.group, state, &fail(&2, &1))

  defp plan(%{detected: :mismatch} = p, state, _),
    do: Enum.reduce(p.group, state, &finish(&2, &1))

  defp plan(%{detected: {:ok, found}} = p, state, summaries) do
    reference = reference(found)

    {current, changed} =
      p.group
      |> Enum.map(fn row ->
        kept = kept_candidate(row, found)
        replaced = replaced_candidate(row, found)
        branch_pr = reference || if(terminal?(summaries, kept), do: kept)
        {row, branch_pr, if(terminal?(summaries, replaced), do: reference)}
      end)
      |> Enum.split_with(fn {row, branch_pr, replacement} ->
        same?(row["branchPullRequest"], branch_pr) and replacement == nil
      end)

    state = Enum.reduce(current, state, fn {row, _, _}, state -> finish(state, row) end)

    if changed != [] and reference != nil and not confirmed?(p) do
      Enum.reduce(changed, state, fn {row, _, _}, state -> fail(state, row) end)
    else
      Enum.reduce(changed, state, &write(&2, p, &1))
    end
  end

  # A cached answer is asked for again before anything is written from it.
  defp confirmed?(%{fetched?: true}), do: true

  defp confirmed?(%{group: [%{"branch" => branch} | _], detected: {:ok, found}} = p) do
    case GitHub.branch_pull_request(p.cwd, branch) do
      {:ok, %{} = fresh} ->
        Map.take(fresh, ~w(number url state)) == Map.take(found, ~w(number url state))

      _ ->
        false
    end
  end

  defp write(state, p, {row, branch_pr, replacement}) do
    command =
      Map.merge(
        %{
          "type" => "thread.pull-request.sync",
          "commandId" => "server:thread-pull-request:#{row["id"]}:#{T3.Environment.uuid4()}",
          "threadId" => row["id"],
          "projectId" => p.project["id"],
          "expected" => %{
            "workspaceRoot" => p.project["workspaceRoot"],
            "branch" => row["branch"],
            "worktreePath" => row["worktreePath"],
            "linkedPullRequest" => row["linkedPullRequest"],
            "branchPullRequest" => row["branchPullRequest"]
          },
          "branchPullRequest" => branch_pr
        },
        if(replacement, do: %{"linkedPullRequest" => replacement}, else: %{})
      )

    case Orchestration.dispatch(command) do
      {:ok, _} ->
        finish(state, row)

      {:error, reason} ->
        Logger.warning("thread pull request update skipped for #{row["id"]}: #{inspect(reason)}")
        fail(state, row)
    end
  end

  defp same?(nil, nil), do: true
  defp same?(nil, _), do: false
  defp same?(_, nil), do: false

  defp same?(left, right),
    do:
      left["projectId"] == right["projectId"] and
        String.downcase(left["repository"]) == String.downcase(right["repository"]) and
        left["number"] == right["number"] and left["url"] == right["url"]

  defp finish(state, row), do: %{state | backfill: Map.delete(state.backfill, row["id"])}

  defp fail(state, row) do
    case state.backfill[row["id"]] do
      nil -> state
      left when left <= 1 -> finish(state, row)
      left -> %{state | backfill: Map.put(state.backfill, row["id"], left - 1)}
    end
  end

  defp project(id) do
    case T3.Shell.row(node(), id) do
      {"project", row} -> if row["deletedAt"] == nil, do: row
      _ -> nil
    end
  end

  defp remote(root) do
    with remote when is_binary(remote) <- T3.Git.primary_remote(root),
         {:ok, url} <- T3.Git.ok(root, ["remote", "get-url", remote]),
         do: T3.PullRequests.parse_remote(url),
         else: (_ -> nil)
  end
end
