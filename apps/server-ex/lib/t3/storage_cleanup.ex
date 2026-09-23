defmodule T3.StorageCleanup do
  @moduledoc """
  Removes what the user's storage settings say may go, as the Node server does:
  thread worktrees under `<home>/worktrees` (after days idle, once merged, once
  their thread is deleted, or when their branch is already in the default
  branch), and browser artifacts past their age.

  A sweep runs an hour apart and when the cleanup settings change. It is
  deliberately timid: a worktree goes only when exactly one thread uses it, that
  thread is idle, nothing (a terminal, a provider session, another project) lives
  in it, it is a linked checkout on the thread's branch with no changes and no
  ignored files besides `node_modules`, and all of that still holds, with the same
  rules, just before removal. The branch and path stay on the thread, so it can
  check the worktree out again.
  """

  use GenServer

  require Logger

  alias T3.Git

  @day_ms 86_400_000
  @off %{
    "worktreeAfterDays" => nil,
    "worktreeOnMerge" => false,
    "worktreeOnDelete" => false,
    "worktreeUnchanged" => false
  }

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "Runs a sweep now and waits for it."
  def sweep, do: GenServer.call(__MODULE__, :sweep, :timer.minutes(5))

  @doc "The worktree rules for a project: its override, else the environment's."
  def rules(settings, project_id) do
    case T3.Settings.resolve(settings, project_id)["worktreeCleanup"] do
      %{"mode" => "custom", "rules" => rules} -> Map.merge(@off, rules)
      %{"mode" => "off"} -> @off
      _ -> Map.merge(@off, Map.take(settings["storageCleanup"] || %{}, Map.keys(@off)))
    end
  end

  @impl true
  def init(nil) do
    T3.Settings.watch(self())
    schedule(Application.get_env(:t3, :storage_cleanup_first_ms, 60_000))
    {:ok, %{policy: nil}}
  end

  @impl true
  def handle_call(:sweep, _from, state) do
    run()
    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:tick, state) do
    run()
    schedule(:timer.hours(1))
    {:noreply, state}
  end

  # A changed policy is applied at once; other settings changes are not a reason to sweep.
  def handle_info({:t3_settings, _node, settings}, state) do
    policy = policy(settings)
    if state.policy != nil and policy != state.policy, do: run()
    {:noreply, %{state | policy: policy}}
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp schedule(nil), do: :ok
  defp schedule(ms), do: Process.send_after(self(), :tick, ms)

  defp policy(settings) do
    overrides =
      for {id, %{"worktreeCleanup" => rule}} <- settings["projectSettingsOverrides"] || %{},
          do: {id, rule}

    {settings["storageCleanup"], settings["worktreeCleanup"], Map.new(overrides)}
  end

  defp run do
    settings = T3.Settings.settings()
    now = System.system_time(:millisecond)

    try do
      worktrees(settings, now)
    rescue
      error -> Logger.warning("worktree cleanup failed: #{Exception.message(error)}")
    end

    days = get_in(settings, ["storageCleanup", "browserArtifactsAfterDays"])
    files(Path.join(home(), "browser-artifacts"), days, now)
  end

  # --- worktrees -----------------------------------------------------------------

  defp worktrees(settings, now) do
    root = Path.join(home(), "worktrees")
    rows = for {{node, _id}, row} <- T3.Shell.rows(), node == node(), do: row
    projects = for {"project", project} <- rows, into: %{}, do: {project["id"], project}
    threads = for {"thread", thread} <- rows, is_binary(thread["worktreePath"]), do: thread

    if any_policy?(settings, projects) and File.dir?(root) do
      {:ok, root} = real(root)
      {deleted, live} = Enum.split_with(threads, &(&1["deletedAt"] != nil))
      groups = Enum.group_by(live, &Path.expand(&1["worktreePath"]))

      candidates =
        for({_path, [thread]} <- groups, do: thread) ++
          for thread <- deleted,
              not Map.has_key?(groups, Path.expand(thread["worktreePath"])),
              rules(settings, thread["projectId"])["worktreeOnDelete"],
              do: thread

      Enum.reduce(candidates, %{}, fn thread, fetched ->
        try do
          clean(thread, projects, settings, root, now, fetched)
        rescue
          error ->
            Logger.debug("storage cleanup skipped #{thread["id"]}: #{Exception.message(error)}")
            fetched
        end
      end)
    end
  end

  defp any_policy?(settings, projects) do
    ids = [nil | Map.keys(settings["projectSettingsOverrides"] || %{}) ++ Map.keys(projects)]
    Enum.any?(ids, &enabled?(rules(settings, &1)))
  end

  defp enabled?(rules) do
    rules["worktreeAfterDays"] != nil or rules["worktreeOnMerge"] or rules["worktreeOnDelete"] or
      rules["worktreeUnchanged"]
  end

  # `fetched` holds the default branches already fetched this sweep, by repository.
  defp clean(thread, projects, settings, root, now, fetched) do
    rules = rules(settings, thread["projectId"])
    path = Path.expand(thread["worktreePath"])
    deleted = thread["deletedAt"] != nil
    project = projects[thread["projectId"]]

    with true <- enabled?(rules),
         %{"workspaceRoot" => repo} <- project,
         true <- deleted or idle?(thread),
         false <- busy?(path),
         {:ok, head} <- checkout(path, root, thread["branch"], Map.values(projects)),
         {eligible, fetched} <- eligible(thread, rules, repo, path, head, deleted, now, fetched),
         true <- eligible,
         true <- still?(thread, path, head, rules, deleted, projects) do
      with {:ok, _} <- T3.Vcs.remove_worktree(%{"cwd" => repo, "path" => path}),
           do: Logger.info("storage cleanup removed the worktree of #{thread["id"]}")

      fetched
    else
      {false, fetched} -> fetched
      _ -> fetched
    end
  end

  # Idle with nothing pending; a live session is checked separately (`busy?/1`).
  defp idle?(thread) do
    thread["branch"] != nil and thread["activeRunId"] == nil and
      thread["status"] in ["idle", "failed", "completed", "interrupted", "cancelled"] and
      (thread["pendingBackgroundTasks"] || []) == [] and thread["pendingRuntimeRequest"] == nil
  end

  # A running terminal, or a provider session of a thread, working in the worktree.
  defp busy?(path) do
    terminal =
      Enum.any?(T3.Terminal.Hub.summaries(), fn t ->
        t["status"] in ["starting", "running"] and
          ((is_binary(t["worktreePath"]) and Path.expand(t["worktreePath"]) == path) or
             within?(Path.expand(t["cwd"] || "/"), path))
      end)

    session =
      Enum.any?(T3.Shell.rows(), fn
        {{node, id}, {"thread", %{"worktreePath" => wt}}} when node == node() and is_binary(wt) ->
          within?(Path.expand(wt), path) and session?(id)

        _ ->
          false
      end)

    terminal or session
  end

  defp session?(thread_id) do
    Enum.any?(
      [T3.Codex.Registry, T3.Claude.Registry, T3.Acp.Registry],
      &(Process.whereis(&1) != nil and Registry.lookup(&1, thread_id) != [])
    )
  end

  # A linked checkout of `branch` under the worktrees root, clean, holding no project
  # and no ignored files but dependencies: `{:ok, head}`.
  defp checkout(path, root, branch, projects) do
    with true <- within?(path, root) and path != root,
         {:ok, ^path} <- real(path),
         false <- holds_project?(path, projects),
         {:ok, %File.Stat{type: :regular}} <- File.stat(Path.join(path, ".git")),
         {:ok, ^branch} <- git(path, ~w(rev-parse --abbrev-ref HEAD)),
         {:ok, ""} <- git(path, ~w(status --porcelain)),
         {:ok, head} <- git(path, ~w(rev-parse HEAD)),
         true <- only_dependencies_ignored?(path) do
      {:ok, head}
    else
      _ -> :skip
    end
  end

  defp holds_project?(path, projects) do
    Enum.any?(projects, fn %{"workspaceRoot" => root} ->
      root = Path.expand(root)
      real_root = with({:ok, real} <- real(root), do: real, else: (_ -> root))
      within?(root, path) or within?(real_root, path)
    end)
  end

  # Ignored files can be secrets or local data; installed dependencies can come back.
  defp only_dependencies_ignored?(path) do
    case Git.ok(path, ~w(ls-files --others --ignored --exclude-standard --directory -z)) do
      {:ok, out} when byte_size(out) <= 64 * 1024 ->
        out
        |> String.split(<<0>>, trim: true)
        |> Enum.all?(&Regex.match?(~r{(^|/)node_modules/$}, &1))

      _ ->
        false
    end
  end

  defp eligible(thread, rules, repo, path, head, deleted, now, fetched) do
    days = rules["worktreeAfterDays"]
    old = not deleted and days != nil and activity_at(thread) < now - days * @day_ms

    cond do
      deleted or old ->
        {true, fetched}

      rules["worktreeUnchanged"] or rules["worktreeOnMerge"] ->
        with {:ok, remote, branch} <- default_branch(repo),
             ref = "refs/remotes/#{remote}/#{branch}",
             fetched = fetch_once(fetched, repo, remote, branch),
             {:ok, base} <- git(path, ["rev-parse", ref]),
             {:ok, %{status: 0}} <- Git.run(path, ["merge-base", "--is-ancestor", head, base]) do
          merged =
            rules["worktreeUnchanged"] or
              match?(%{"state" => "merged"}, T3.Vcs.branch_pull_request(path, thread["branch"]))

          {merged, fetched}
        else
          _ -> {false, fetched}
        end

      true ->
        {false, fetched}
    end
  end

  defp default_branch(repo) do
    remote =
      case git(repo, ~w(remote)) do
        {:ok, remotes} ->
          names = String.split(remotes, "\n", trim: true)
          if "origin" in names, do: "origin", else: List.first(names)

        _ ->
          nil
      end

    with true <- remote != nil,
         {:ok, "refs/remotes/" <> rest} <-
           git(repo, ["symbolic-ref", "refs/remotes/#{remote}/HEAD"]),
         [_, branch] <- String.split(rest, "/", parts: 2) do
      {:ok, remote, branch}
    else
      _ -> :none
    end
  end

  defp fetch_once(fetched, repo, remote, branch) do
    key = {repo, remote, branch}

    if Map.has_key?(fetched, key) do
      fetched
    else
      _ = Git.run(repo, ["fetch", remote, branch])
      Map.put(fetched, key, true)
    end
  end

  # PR refreshes must not reset the clock, so only messages and runs count.
  defp activity_at(thread) do
    ~w(createdAt latestUserMessageAt latestRunRequestedAt latestRunStartedAt latestRunCompletedAt)
    |> Enum.map(&thread[&1])
    |> Enum.flat_map(fn
      at when is_binary(at) ->
        case DateTime.from_iso8601(at) do
          {:ok, time, _} -> [DateTime.to_unix(time, :millisecond)]
          _ -> []
        end

      _ ->
        []
    end)
    |> Enum.max(fn -> 0 end)
  end

  # Git and host calls take time; everything is checked again against fresh rows
  # and settings so a new turn, session, thread or rule change cancels the removal.
  defp still?(thread, path, head, rules, deleted, projects) do
    rows = for {{node, _id}, row} <- T3.Shell.rows(), node == node(), do: row

    sharing =
      for {"thread", t} <- rows,
          t["deletedAt"] == nil,
          is_binary(t["worktreePath"]),
          Path.expand(t["worktreePath"]) == path,
          do: t

    fresh_projects = for {"project", p} <- rows, do: p

    id = thread["id"]

    thread_ok =
      case sharing do
        [] ->
          deleted

        [%{"id" => ^id} = fresh] ->
          not deleted and idle?(fresh) and activity_at(fresh) == activity_at(thread)

        _ ->
          false
      end

    thread_ok and not busy?(path) and not holds_project?(path, fresh_projects) and
      checkout(
        path,
        Path.join(home(), "worktrees") |> real_or_self(),
        thread["branch"],
        Map.values(projects)
      ) ==
        {:ok, head} and
      rules(T3.Settings.settings(), thread["projectId"]) == rules
  end

  # --- files -----------------------------------------------------------------------

  defp files(_dir, nil, _now), do: :ok

  defp files(dir, days, now) do
    with true <- File.dir?(dir),
         {:ok, ^dir} <- real(dir),
         {:ok, names} <- File.ls(dir) do
      for name <- names,
          path = Path.join(dir, name),
          {:ok, %File.Stat{type: :regular, mtime: mtime}} <- [File.lstat(path, time: :posix)],
          mtime * 1000 < now - days * @day_ms,
          get_in(T3.Settings.settings(), ["storageCleanup", "browserArtifactsAfterDays"]) == days,
          do: File.rm(path)
    end

    :ok
  end

  # --- paths -----------------------------------------------------------------------

  defp git(cwd, args) do
    with {:ok, out} <- Git.ok(cwd, args), do: {:ok, String.trim(out)}
  end

  defp within?(path, root), do: path == root or String.starts_with?(path, root <> "/")

  defp real(path), do: T3.Paths.real(path)

  defp real_or_self(path), do: with({:ok, real} <- real(path), do: real, else: (_ -> path))

  defp home, do: Application.fetch_env!(:t3, :home)
end
