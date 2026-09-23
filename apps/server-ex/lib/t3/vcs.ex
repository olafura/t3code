defmodule T3.Vcs do
  @moduledoc """
  Git for the Version Control panel: status (`vcs.refreshStatus`, and the stream in
  `T3.Vcs.Watch`), refs (`vcs.listRefs`, `vcs.switchRef`, `vcs.createRef`),
  `vcs.init`, `vcs.pull`, and worktrees (`vcs.createWorktree`,
  `vcs.removeWorktree`), in the shapes of `packages/contracts/src/git.ts`.

  Every change to a checkout refreshes its watched status.
  """

  alias T3.Git

  @refs_limit 100

  # --- status ---------------------------------------------------------------------

  @doc "`VcsStatusLocalResult` for a directory; a non-repository reports `isRepo: false`."
  def local_status(cwd) do
    with true <- File.dir?(cwd),
         {:ok, %{status: 0, out: status}} <-
           Git.run(cwd, ~w(status --porcelain=2 --branch -z --untracked-files=all)) do
      branch = parse_branch(status)
      changed = changed_paths(status)
      stats = numstat(cwd)
      default = default_branch(cwd)

      # Untracked and binary files have no line counts but are still changes.
      files =
        (for(
           {path, {ins, del}} <- stats,
           do: %{"path" => path, "insertions" => ins, "deletions" => del}
         ) ++
           for(
             path <- changed,
             not Map.has_key?(stats, path),
             do: %{"path" => path, "insertions" => 0, "deletions" => 0}
           ))
        |> Enum.sort_by(& &1["path"])

      %{
        "isRepo" => true,
        "hasPrimaryRemote" => Git.primary_remote(cwd) == "origin",
        "isDefaultRef" => default_ref?(branch.head, default),
        "refName" => branch.head,
        "hasWorkingTreeChanges" => changed != [],
        "workingTree" => %{
          "files" => files,
          "insertions" => Enum.sum_by(files, & &1["insertions"]),
          "deletions" => Enum.sum_by(files, & &1["deletions"])
        }
      }
    else
      _ -> not_a_repo()
    end
  end

  # Without a known default branch, main and master count as the default.
  defp default_ref?(nil, _default), do: false
  defp default_ref?(head, nil), do: head in ["main", "master"]
  defp default_ref?(head, default), do: head == default

  defp not_a_repo,
    do: %{
      "isRepo" => false,
      "hasPrimaryRemote" => false,
      "isDefaultRef" => false,
      "refName" => nil,
      "hasWorkingTreeChanges" => false,
      "workingTree" => %{"files" => [], "insertions" => 0, "deletions" => 0}
    }

  @doc """
  `VcsStatusRemoteResult`, or nil outside a repository. With `fetch: true` the
  upstream is fetched first so the behind count is current; with `pr: true` the
  branch's GitHub pull request is looked up (otherwise `pr` is nil).
  """
  def remote_status(cwd, opts \\ []) do
    with true <- File.dir?(cwd),
         {:ok, %{status: 0, out: status}} <- Git.run(cwd, ~w(status --porcelain=2 --branch -z)) do
      branch = parse_branch(status)

      branch =
        if opts[:fetch] && branch.upstream do
          [remote | _] = String.split(branch.upstream, "/", parts: 2)
          Git.run(cwd, ["fetch", "--quiet", "--no-tags", remote], max_bytes: 64 * 1024)
          {:ok, %{out: status}} = Git.run(cwd, ~w(status --porcelain=2 --branch -z))
          parse_branch(status)
        else
          branch
        end

      default = default_branch(cwd)
      base = branch.head && Git.base_branch(cwd, branch.head)
      ahead_of_base = if base, do: count(cwd, "#{base}..HEAD"), else: 0
      default? = default_ref?(branch.head, default)

      %{
        "hasUpstream" => branch.upstream != nil,
        "aheadCount" => if(branch.upstream, do: branch.ahead, else: ahead_of_base),
        "behindCount" => if(branch.upstream, do: branch.behind, else: 0),
        "aheadOfDefaultCount" => if(branch.head && not default?, do: ahead_of_base, else: 0),
        "pr" => if(opts[:pr] && branch.head, do: pull_request(cwd, branch.head, default?))
      }
    else
      _ -> nil
    end
  end

  @doc "`vcs.refreshStatus`: both halves, fetched fresh; watchers are told too."
  def refresh_status(%{"cwd" => cwd}) do
    local = local_status(cwd)
    remote = remote_status(cwd, fetch: true, pr: true)
    T3.Vcs.Watch.publish(cwd, local, remote)
    {:ok, Map.merge(local, remote || empty_remote())}
  end

  # The branch's latest GitHub pull request, through `gh`. On the default branch
  # only an open one counts: merged or closed matches there are reverse merges.
  defp pull_request(cwd, branch, default?) do
    with gh when is_binary(gh) <- System.find_executable("gh"),
         {:ok, url} <- Git.ok(cwd, ~w(remote get-url origin)),
         true <- String.contains?(url, "github.com"),
         [pr | _] <- gh_pr_list(gh, cwd, branch),
         state = String.downcase(pr["state"] || "open"),
         true <- state == "open" or not default? do
      %{
        "number" => pr["number"],
        "title" => pr["title"],
        "url" => pr["url"],
        "baseRef" => pr["baseRefName"],
        "headRef" => pr["headRefName"],
        "state" => state,
        "isDraft" => pr["isDraft"] == true,
        "updatedAt" => pr["updatedAt"]
      }
    else
      _ -> nil
    end
  end

  defp gh_pr_list(gh, cwd, branch) do
    args =
      ~w(pr list --state all --limit 1 --json number,title,url,baseRefName,headRefName,state,isDraft,updatedAt --head) ++
        [branch]

    # Unauthenticated or offline `gh` means no pull request, quietly.
    task = Task.async(fn -> System.cmd(gh, args, cd: cwd, stderr_to_stdout: true) end)

    case Task.yield(task, 10_000) || Task.shutdown(task, :brutal_kill) do
      {:ok, {out, 0}} -> JSON.decode!(out)
      _ -> []
    end
  rescue
    _ -> []
  end

  defp empty_remote,
    do: %{"hasUpstream" => false, "aheadCount" => 0, "behindCount" => 0, "pr" => nil}

  defp parse_branch(status) do
    status
    |> String.split(<<0>>)
    |> Enum.reduce(%{head: nil, upstream: nil, ahead: 0, behind: 0}, fn
      "# branch.head " <> head, acc ->
        %{acc | head: if(String.starts_with?(head, "("), do: nil, else: head)}

      "# branch.upstream " <> upstream, acc ->
        %{acc | upstream: upstream}

      "# branch.ab " <> ab, acc ->
        case Regex.run(~r/^\+(\d+) -(\d+)$/, ab) do
          [_, ahead, behind] ->
            %{acc | ahead: String.to_integer(ahead), behind: String.to_integer(behind)}

          _ ->
            acc
        end

      _, acc ->
        acc
    end)
  end

  # Paths of changed entries in `git status --porcelain=2 -z`. A rename (`2`) is
  # followed by a record holding its original path, which is skipped.
  defp changed_paths(status) do
    status
    |> String.split(<<0>>, trim: true)
    |> parse_changed([])
    |> Enum.reverse()
    |> Enum.uniq()
  end

  defp parse_changed([], acc), do: acc
  defp parse_changed(["#" <> _ | rest], acc), do: parse_changed(rest, acc)

  defp parse_changed(["1 " <> fields | rest], acc),
    do: parse_changed(rest, [fields |> String.split(" ", parts: 8) |> List.last() | acc])

  defp parse_changed(["2 " <> fields | rest], acc) do
    path = fields |> String.split(" ", parts: 9) |> List.last()
    parse_changed(Enum.drop(rest, 1), [path | acc])
  end

  defp parse_changed(["u " <> fields | rest], acc),
    do: parse_changed(rest, [fields |> String.split(" ", parts: 10) |> List.last() | acc])

  defp parse_changed(["? " <> path | rest], acc), do: parse_changed(rest, [path | acc])
  defp parse_changed([_ | rest], acc), do: parse_changed(rest, acc)

  # Line counts against HEAD; before the first commit, staged plus unstaged.
  defp numstat(cwd) do
    case Git.run(cwd, ~w(diff HEAD --numstat -z --)) do
      {:ok, %{status: 0, out: out}} ->
        parse_numstat(out)

      _ ->
        Map.merge(
          numstat_of(cwd, ~w(diff --numstat -z)),
          numstat_of(cwd, ~w(diff --cached --numstat -z)),
          fn _, {a, b}, {c, d} -> {a + c, b + d} end
        )
    end
  end

  defp numstat_of(cwd, args) do
    case Git.ok(cwd, args) do
      {:ok, out} -> parse_numstat(out)
      _ -> %{}
    end
  end

  defp parse_numstat(out) do
    for %{"path" => path, "additions" => ins, "deletions" => del} <-
          T3.Review.numstat(out),
        into: %{},
        do: {path, {ins, del}}
  end

  defp default_branch(cwd) do
    case Git.ok(cwd, ~w(symbolic-ref refs/remotes/origin/HEAD)) do
      {:ok, "refs/remotes/origin/" <> branch} -> String.trim(branch)
      _ -> nil
    end
  end

  defp count(cwd, range) do
    case Git.ok(cwd, ["rev-list", "--count", range]) do
      {:ok, n} -> String.to_integer(String.trim(n))
      _ -> 0
    end
  end

  # --- refs -----------------------------------------------------------------------

  @doc """
  `vcs.listRefs`: the current and default refs first, then by last commit; remote
  refs that mirror a local branch are left out unless asked for.
  """
  def list_refs(%{"cwd" => cwd} = input) do
    with true <- File.dir?(cwd),
         {:ok, root} <- Git.ok(cwd, ~w(rev-parse --show-toplevel)) do
      root = String.trim(root)
      remotes = remotes(cwd)
      default = default_branch(cwd)
      worktrees = worktree_branches(cwd)
      current = Git.current_branch(cwd)
      in_worktree = Enum.any?(worktrees, fn {_, path} -> path == root end)

      {:ok, out} =
        Git.ok(
          cwd,
          ~w(for-each-ref --format=%\(refname\)%09%\(committerdate:unix\)%09%\(symref\) refs/heads refs/remotes)
        )

      {locals, remote_refs} =
        out
        |> String.split("\n", trim: true)
        |> Enum.map(&String.split(&1, "\t"))
        |> Enum.filter(&match?([_, _, ""], &1))
        |> Enum.map(fn [ref, time, _] -> {ref, String.to_integer(time)} end)
        |> Enum.sort_by(fn {ref, time} -> {-time, ref} end)
        |> Enum.split_with(fn {ref, _} -> String.starts_with?(ref, "refs/heads/") end)

      locals =
        for {"refs/heads/" <> name, _} <- locals do
          path = worktrees[name]

          %{
            "name" => name,
            "current" => if(in_worktree, do: path == root, else: name == current),
            "isRemote" => false,
            "isDefault" => name == default,
            "worktreePath" => path
          }
        end

      remote_refs =
        for {"refs/remotes/" <> name, _} <- remote_refs do
          remote = Enum.find(remotes, &String.starts_with?(name, &1 <> "/"))
          branch = remote && String.replace_prefix(name, remote <> "/", "")

          %{
            "name" => name,
            "current" => false,
            "isRemote" => true,
            "isDefault" => remote == "origin" and branch == default,
            "worktreePath" => nil
          }
          |> then(&if(remote, do: Map.put(&1, "remoteName", remote), else: &1))
        end

      local_names = MapSet.new(locals, & &1["name"])

      remote_refs =
        if input["includeMatchingRemoteRefs"],
          do: remote_refs,
          else:
            Enum.reject(remote_refs, fn ref ->
              ref["remoteName"] == "origin" and
                MapSet.member?(local_names, String.replace_prefix(ref["name"], "origin/", ""))
            end)

      query = input["query"] && String.downcase(input["query"])

      refs =
        (locals ++ remote_refs)
        |> Enum.sort_by(fn ref ->
          cond do
            ref["current"] -> 0
            ref["isDefault"] -> 1
            true -> 2
          end
        end)
        |> Enum.filter(fn ref ->
          case input["refKind"] do
            "local" -> not ref["isRemote"]
            "remote" -> ref["isRemote"]
            _ -> true
          end
        end)
        |> Enum.filter(&(query == nil or String.contains?(String.downcase(&1["name"]), query)))

      cursor = input["cursor"] || 0
      limit = input["limit"] || @refs_limit
      page = refs |> Enum.drop(cursor) |> Enum.take(limit)
      total = length(refs)

      {:ok,
       %{
         "refs" => page,
         "isRepo" => true,
         "hasPrimaryRemote" => "origin" in remotes,
         "nextCursor" => if(cursor + length(page) < total, do: cursor + length(page)),
         "totalCount" => total
       }}
    else
      _ ->
        {:ok,
         %{
           "refs" => [],
           "isRepo" => false,
           "hasPrimaryRemote" => false,
           "nextCursor" => nil,
           "totalCount" => 0
         }}
    end
  end

  defp remotes(cwd) do
    case Git.ok(cwd, ["remote"]) do
      {:ok, out} -> out |> String.split("\n", trim: true) |> Enum.sort_by(&(-String.length(&1)))
      _ -> []
    end
  end

  # Branch name to the worktree it is checked out in, for worktrees still on disk.
  defp worktree_branches(cwd) do
    case Git.ok(cwd, ~w(worktree list --porcelain -z)) do
      {:ok, out} ->
        out
        |> String.split(<<0, 0>>, trim: true)
        |> Enum.flat_map(fn entry ->
          fields = String.split(entry, <<0>>, trim: true)

          path =
            Enum.find_value(
              fields,
              &(match?("worktree " <> _, &1) && String.replace_prefix(&1, "worktree ", ""))
            )

          branch =
            Enum.find_value(
              fields,
              &(match?("branch refs/heads/" <> _, &1) &&
                  String.replace_prefix(&1, "branch refs/heads/", ""))
            )

          prunable = Enum.any?(fields, &String.starts_with?(&1, "prunable"))

          if path && branch && not prunable && File.dir?(path), do: [{branch, path}], else: []
        end)
        |> Map.new()

      _ ->
        %{}
    end
  end

  @doc """
  `vcs.switchRef`. A remote ref checks out the local branch tracking it, creating
  one when there is none.
  """
  def switch_ref(%{"cwd" => cwd, "refName" => ref}) do
    local? = ref?(cwd, "refs/heads/#{ref}")
    remote? = ref?(cwd, "refs/remotes/#{ref}")
    tracking = if remote?, do: tracking_branch(cwd, ref)
    derived = ref |> String.split("/", parts: 2) |> List.last()

    args =
      cond do
        local? -> ["checkout", ref]
        remote? and tracking -> ["checkout", tracking]
        remote? and ref?(cwd, "refs/heads/#{derived}") -> ["checkout", ref]
        remote? -> ["checkout", "--track", ref]
        true -> ["checkout", ref]
      end

    # A stale ref must not turn into a path checkout that discards local edits.
    with :ok <- run(cwd, args ++ ["--"], "vcs.switchRef", "git checkout failed") do
      changed(cwd)
      {:ok, %{"refName" => Git.current_branch(cwd)}}
    end
  end

  defp tracking_branch(cwd, remote_ref) do
    case Git.ok(
           cwd,
           ~w(for-each-ref --format=%\(refname:short\)%09%\(upstream:short\) refs/heads)
         ) do
      {:ok, out} ->
        Enum.find_value(String.split(out, "\n", trim: true), fn line ->
          case String.split(line, "\t") do
            [branch, ^remote_ref] -> branch
            _ -> nil
          end
        end)

      _ ->
        nil
    end
  end

  @doc "`vcs.createRef`: a branch at HEAD, switched to when asked."
  def create_ref(%{"cwd" => cwd, "refName" => ref} = input) do
    with :ok <- run(cwd, ["branch", ref], "vcs.createRef", "git branch create failed"),
         {:ok, _} <- if(input["switchRef"], do: switch_ref(input), else: {:ok, nil}) do
      changed(cwd)
      {:ok, %{"refName" => ref}}
    end
  end

  @doc "`vcs.init`."
  def init(%{"cwd" => cwd}) do
    case Git.run(cwd, ["init"]) do
      {:ok, %{status: 0}} ->
        changed(cwd)
        {:ok, nil}

      result ->
        {:error,
         %{
           "_tag" => "VcsProcessExitError",
           "operation" => "vcs.init",
           "command" => "git init",
           "cwd" => cwd,
           "exitCode" => exit_code(result),
           "detail" => "git init failed",
           "message" => "git init failed in #{cwd}"
         }}
    end
  end

  @doc "`vcs.pull`: a fast-forward pull of the current branch from its upstream."
  def pull(%{"cwd" => cwd}) do
    status = remote_status(cwd)
    branch = Git.current_branch(cwd)

    cond do
      branch == nil ->
        {:error, git_error(cwd, "vcs.pull", "Cannot pull from detached HEAD.")}

      status == nil or not status["hasUpstream"] ->
        {:error,
         git_error(
           cwd,
           "vcs.pull",
           "Current branch has no upstream configured. Push with upstream first."
         )}

      true ->
        before = head(cwd)

        with :ok <- run(cwd, ~w(pull --ff-only), "vcs.pull", "git pull failed") do
          changed(cwd)

          upstream =
            case Git.ok(cwd, ~w(rev-parse --abbrev-ref --symbolic-full-name @{upstream})) do
              {:ok, ref} -> String.trim(ref)
              _ -> nil
            end

          {:ok,
           %{
             "status" =>
               if(before != nil and before == head(cwd), do: "skipped_up_to_date", else: "pulled"),
             "refName" => branch,
             "upstreamRef" => upstream
           }}
        end
    end
  end

  defp head(cwd) do
    case Git.ok(cwd, ~w(rev-parse HEAD)) do
      {:ok, sha} -> String.trim(sha)
      _ -> nil
    end
  end

  # --- worktrees ------------------------------------------------------------------

  @doc """
  `vcs.createWorktree`: checks out `refName` (or a new branch from it) in a new
  worktree, by default `<home>/worktrees/<repo>/<branch>`, with its submodules.
  """
  def create_worktree(%{"cwd" => cwd, "refName" => ref} = input) do
    branch = input["newRefName"] || ref
    home = Application.fetch_env!(:t3, :home)

    path =
      input["path"] ||
        Path.join([home, "worktrees", Path.basename(cwd), String.replace(branch, "/", "-")])

    args =
      if input["newRefName"],
        do: ["worktree", "add", "-b", input["newRefName"], path, ref],
        else: ["worktree", "add", path, ref]

    with :ok <- run(cwd, args, "vcs.createWorktree", "git worktree add failed") do
      # `git worktree add` leaves submodules empty; filling them is best effort.
      if File.exists?(Path.join(path, ".gitmodules")),
        do: Git.run(path, ~w(submodule update --init))

      changed(cwd)
      {:ok, %{"worktree" => %{"path" => path, "refName" => branch}}}
    end
  end

  @doc "`vcs.removeWorktree`; a worktree that is already gone is pruned instead."
  def remove_worktree(%{"cwd" => cwd, "path" => path} = input) do
    args = ["worktree", "remove"] ++ if(input["force"], do: ["--force"], else: []) ++ [path]

    case Git.run(cwd, args) do
      {:ok, %{status: 0}} ->
        changed(cwd)
        {:ok, nil}

      {:ok, _} ->
        if File.exists?(path) do
          {:error, git_error(cwd, "vcs.removeWorktree", "git worktree remove failed")}
        else
          Git.run(cwd, ~w(worktree prune))
          changed(cwd)
          {:ok, nil}
        end

      {:error, reason} ->
        {:error, git_error(cwd, "vcs.removeWorktree", reason)}
    end
  end

  # --- helpers --------------------------------------------------------------------

  defp changed(cwd), do: T3.Vcs.Watch.refresh(cwd)

  defp ref?(cwd, ref), do: match?({:ok, _}, Git.ok(cwd, ["show-ref", "--verify", "--quiet", ref]))

  defp run(cwd, args, operation, detail) do
    case Git.run(cwd, args, max_bytes: 1024 * 1024) do
      {:ok, %{status: 0}} ->
        :ok

      {:ok, %{status: status, err: err}} ->
        # Git's own message says what went wrong ("would be overwritten", ...).
        message = err |> String.trim() |> String.split("\n") |> Enum.take(-3) |> Enum.join(" ")

        {:error,
         git_error(cwd, operation, if(message == "", do: detail, else: message))
         |> Map.merge(%{
           "command" => "git #{hd(args)}",
           "exitCode" => exit_code({:ok, %{status: status}})
         })}

      {:error, reason} ->
        {:error, git_error(cwd, operation, reason)}
    end
  end

  defp exit_code({:ok, %{status: status}}) when is_integer(status), do: status
  defp exit_code(_), do: nil

  defp git_error(cwd, operation, detail),
    do: %{
      "_tag" => "GitCommandError",
      "operation" => operation,
      "command" => "git",
      "cwd" => cwd,
      "detail" => to_string(detail),
      "message" => "Git command failed in #{operation} (#{cwd}): #{detail}"
    }
end
