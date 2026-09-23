defmodule T3.PullRequests.Checkout do
  @moduledoc """
  Opening a pull request in a thread (`git.resolvePullRequest`,
  `git.preparePullRequestThread`). The pull request is read through `gh` in the
  project's checkout (a number, `#number`, or a URL), then checked out there with
  `gh pr checkout` (`local`) or fetched from `refs/pull/<n>/head` into a worktree of
  its own (`worktree`). A worktree that already holds the branch is reused and moved
  forward when it can be.

  A fork's branch is fetched under `t3code/pr-<n>/<branch>` and gets no upstream.
  The project's setup script is not run for the new worktree.
  """

  alias T3.{Git, PullRequests.GitHub}

  @fields "number,title,url,baseRefName,headRefName,state,isCrossRepository"

  @doc "`git.resolvePullRequest`."
  def resolve(%{"cwd" => cwd, "reference" => reference}) do
    with {:ok, pr} <- read(cwd, reference, "resolvePullRequest"),
         do: {:ok, %{"pullRequest" => resolved(pr)}}
  end

  @doc "`git.preparePullRequestThread`."
  def prepare(%{"cwd" => cwd, "reference" => reference, "mode" => mode}) do
    result =
      with {:ok, pr} <- read(cwd, reference, "preparePullRequestThread") do
        if mode == "local", do: local(cwd, pr), else: worktree(cwd, pr)
      end

    T3.Vcs.Watch.refresh(cwd)
    result
  end

  defp read(cwd, reference, operation) do
    reference = reference |> String.trim() |> String.replace(~r/^#(\d+)$/, "\\1")

    case GitHub.gh(cwd, ["pr", "view", reference, "--json", @fields]) do
      {:ok, out} ->
        case JSON.decode(out) do
          {:ok, %{"number" => number, "headRefName" => head} = pr}
          when is_integer(number) and is_binary(head) ->
            {:ok, pr}

          _ ->
            error(operation, cwd, "gh answered in an unexpected shape.")
        end

      {:error, {_reason, detail}} ->
        error(operation, cwd, detail)
    end
  end

  defp resolved(pr),
    do: %{
      "number" => pr["number"],
      "title" => pr["title"],
      "url" => pr["url"],
      "baseBranch" => pr["baseRefName"],
      "headBranch" => pr["headRefName"],
      "state" => GitHub.state(pr)
    }

  defp local(cwd, pr) do
    case GitHub.gh(cwd, ["pr", "checkout", "#{pr["number"]}", "--force"], timeout: 120_000) do
      {:ok, _} ->
        {:ok,
         %{
           "pullRequest" => resolved(pr),
           "branch" => Git.current_branch(cwd) || pr["headRefName"],
           "worktreePath" => nil,
           "isOnPullRequestHead" => true
         }}

      {:error, {_reason, detail}} ->
        error("preparePullRequestThread", cwd, detail)
    end
  end

  defp worktree(cwd, pr) do
    fork? = pr["isCrossRepository"] == true

    branch =
      if fork?,
        do: "t3code/pr-#{pr["number"]}/#{fragment(pr["headRefName"])}",
        else: pr["headRefName"]

    remote = Git.primary_remote(cwd) || "origin"

    with {:ok, root} <- Git.ok(cwd, ~w(rev-parse --show-toplevel)),
         root = String.trim(root),
         worktrees = worktrees(cwd) do
      case worktrees[branch] do
        ^root ->
          error(
            "preparePullRequestThread",
            cwd,
            "This PR branch is already checked out in the main repo. Use Local, or switch the main repo off that branch before creating a worktree thread."
          )

        path when is_binary(path) ->
          {:ok, prepared(pr, branch, path, advance(path, remote, pr))}

        nil ->
          refspec = "+refs/pull/#{pr["number"]}/head:refs/heads/#{branch}"

          with {:ok, _} <- fetch(cwd, ["fetch", "--quiet", "--no-tags", remote, refspec]),
               {:ok, %{"worktree" => %{"path" => path}}} <-
                 T3.Vcs.create_worktree(%{"cwd" => cwd, "refName" => branch}) do
            unless fork?, do: track(path, remote, branch, pr["headRefName"])
            {:ok, prepared(pr, branch, path, true)}
          end
      end
    else
      {:error, {_status, detail}} -> error("preparePullRequestThread", cwd, detail)
      {:error, _} = error -> error
    end
  end

  defp prepared(pr, branch, path, on_head?),
    do: %{
      "pullRequest" => resolved(pr),
      "branch" => branch,
      "worktreePath" => path,
      "isOnPullRequestHead" => on_head?
    }

  # A reused worktree moves forward to the pull request's head when it holds nothing
  # of its own; otherwise it keeps its state and says it is behind.
  defp advance(path, remote, pr) do
    with {:ok, _} <-
           Git.ok(path, [
             "fetch",
             "--quiet",
             "--no-tags",
             remote,
             "refs/pull/#{pr["number"]}/head"
           ]) do
      Git.ok(path, ~w(merge --ff-only --quiet FETCH_HEAD))

      match?(
        {{:ok, same}, {:ok, same}},
        {Git.ok(path, ~w(rev-parse HEAD)), Git.ok(path, ~w(rev-parse FETCH_HEAD))}
      )
    else
      _ -> false
    end
  end

  # Best effort: the branch follows its own remote branch, so a push lands on the PR.
  defp track(path, remote, branch, head) do
    with {:ok, _} <- Git.ok(path, ["fetch", "--quiet", "--no-tags", remote, head]),
         do: Git.ok(path, ["branch", "--set-upstream-to=#{remote}/#{head}", branch])
  end

  defp fetch(cwd, args) do
    case Git.ok(cwd, args) do
      {:ok, _} = ok -> ok
      {:error, {_status, detail}} -> error("preparePullRequestThread", cwd, detail)
      {:error, detail} -> error("preparePullRequestThread", cwd, detail)
    end
  end

  defp worktrees(cwd) do
    case Git.ok(cwd, ~w(worktree list --porcelain)) do
      {:ok, out} ->
        for entry <- String.split(out, "\n\n", trim: true),
            lines = String.split(entry, "\n"),
            "worktree " <> path <- Enum.take(lines, 1),
            "branch refs/heads/" <> branch <-
              Enum.filter(lines, &String.starts_with?(&1, "branch ")),
            into: %{},
            do: {branch, path}

      _ ->
        %{}
    end
  end

  # As `sanitizeBranchFragment` in packages/shared/src/git.ts.
  defp fragment(raw) do
    fragment =
      raw
      |> String.trim()
      |> String.downcase()
      |> String.replace(~r/['"`]/, "")
      |> String.replace(~r/^[.\/\s_-]+|[.\/\s_-]+$/, "")
      |> String.replace(~r/[^a-z0-9\/_-]+/, "-")
      |> String.replace(~r/\/+/, "/")
      |> String.replace(~r/-+/, "-")
      |> String.replace(~r/^[.\/_-]+|[.\/_-]+$/, "")
      |> String.slice(0, 64)
      |> String.replace(~r/[.\/_-]+$/, "")

    if fragment == "", do: "update", else: fragment
  end

  defp error(operation, cwd, detail),
    do:
      {:error,
       %{
         "_tag" => "GitManagerError",
         "operation" => operation,
         "cwd" => cwd,
         "detail" => to_string(detail),
         "message" => "Git manager failed in #{operation}: #{detail}"
       }}
end
