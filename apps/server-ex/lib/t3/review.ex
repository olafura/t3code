defmodule T3.Review do
  @moduledoc """
  The diff panel's review sources (`review.getDiffPreview`): the dirty working tree
  against HEAD, untracked files included, and the branch against its base branch;
  plus whole-file contents for expanding a diff (`review.getDiffFileContents`).

  Untracked files are shown by adding them intent-to-add to a copy of the index, so
  the user's own index is never touched. Only directories inside this node's
  projects may be reviewed.
  """

  alias T3.Git

  @patch_max 120_000
  @file_max 1024 * 1024
  @metadata_max 16 * 1024 * 1024
  @truncated_marker "\n\n[truncated]"
  @diff_args ~w(diff --find-renames --no-color --no-ext-diff --no-textconv --minimal --src-prefix=a/ --dst-prefix=b/)

  @doc "`review.getDiffPreview` (`ReviewDiffPreviewInput` to `ReviewDiffPreviewResult`)."
  def diff_preview(%{"cwd" => cwd} = input) do
    with :ok <- within_projects(cwd, "getDiffPreview") do
      case Git.ok(cwd, ~w(rev-parse --show-toplevel)) do
        {:ok, root} -> {:ok, preview(String.trim(root), input)}
        {:error, _} -> {:ok, %{"cwd" => cwd, "generatedAt" => now(), "sources" => []}}
      end
    end
  end

  defp preview(root, input) do
    file = input["file"]
    branch = current_branch(root)
    base = input["baseRef"] || (branch && base_branch(root, branch))

    paths =
      if file,
        do: for(p <- [file["path"], file["previousPath"]], p, do: ":(top,literal)#{p}"),
        else: []

    limit = if file, do: @file_max, else: @patch_max
    ignore_ws = if input["ignoreWhitespace"], do: ["--ignore-all-space"], else: []
    diff = fn ref, env -> tracked_diff(root, ref, paths, limit, ignore_ws, env) end

    dirty =
      if file && file["sourceKind"] == "branch-range",
        do: empty_diff(),
        else: dirty_diff(root, paths, file, diff)

    against_base =
      if base && branch && (file == nil or file["sourceKind"] != "working-tree"),
        do: diff.("#{base}...HEAD", []),
        else: empty_diff()

    %{
      "cwd" => input["cwd"],
      "generatedAt" => now(),
      "sources" => [
        source("working-tree", "Dirty worktree", "HEAD", nil, dirty),
        source(
          "branch-range",
          if(base, do: "Against #{base}", else: "Against base branch"),
          base,
          branch || "HEAD",
          against_base
        )
      ]
    }
  end

  defp source(kind, title, base, head, %{diff: diff, files: files, truncated: truncated}) do
    %{
      "id" => kind,
      "kind" => kind,
      "title" => title,
      "baseRef" => base,
      "headRef" => head,
      "diff" => diff,
      "files" => files,
      "diffHash" =>
        :crypto.hash(:sha256, JSON.encode_to_iodata!([diff, files]))
        |> Base.encode16(case: :lower),
      "truncated" => truncated
    }
  end

  defp empty_diff, do: %{diff: "", files: [], truncated: false}

  # Untracked files join the diff as intent-to-add entries in a scratch index.
  defp dirty_diff(root, paths, file, diff) do
    untracked =
      case Git.ok(root, ~w(ls-files --others --exclude-standard -z --) ++ paths,
             max_bytes: @metadata_max
           ) do
        {:ok, out} ->
          out
          |> String.split(<<0>>, trim: true)
          |> Enum.filter(&(file == nil or &1 == file["path"]))

        {:error, _} ->
          []
      end

    case untracked do
      [] -> diff.("HEAD", [])
      _ -> with_intent_index(root, untracked, &diff.("HEAD", &1))
    end
  end

  defp with_intent_index(root, untracked, fun) do
    # A staged deletion stays deleted; re-adding it would hide it.
    deleted =
      case Git.ok(root, ~w(diff --cached --name-only --diff-filter=D -z HEAD --),
             max_bytes: @metadata_max
           ) do
        {:ok, out} -> MapSet.new(String.split(out, <<0>>, trim: true))
        _ -> MapSet.new()
      end

    case Enum.reject(untracked, &MapSet.member?(deleted, &1)) do
      [] ->
        fun.([])

      to_add ->
        {:ok, index} = Git.ok(root, ~w(rev-parse --git-path index))
        index = Path.expand(String.trim(index), root)

        scratch =
          Path.join(System.tmp_dir!(), "t3-review-index-#{System.unique_integer([:positive])}")

        env = [{"GIT_INDEX_FILE", scratch}]
        config = ~w(-c core.splitIndex=false -c splitIndex.sharedIndexExpire=never)

        try do
          if File.exists?(index),
            do: File.cp!(index, scratch),
            else: Git.ok(root, ~w(read-tree --empty), env: env)

          Git.ok(root, config ++ ~w(update-index --no-split-index), env: env)

          Git.ok(
            root,
            config ++
              ~w(--literal-pathspecs add --intent-to-add --pathspec-from-file=- --pathspec-file-nul),
            env: env,
            input: Enum.map_join(to_add, &(&1 <> <<0>>))
          )

          fun.(env)
        after
          File.rm(scratch)
        end
    end
  end

  # Numstat first, for complete file statistics; then the patch, capped at `limit`.
  defp tracked_diff(root, ref, paths, limit, ignore_ws, env) do
    args = @diff_args ++ ignore_ws

    stat =
      case Git.run(root, args ++ ["--numstat", "-z", ref, "--"] ++ paths,
             env: env,
             max_bytes: @metadata_max
           ) do
        {:ok, %{status: 0, out: out}} ->
          {:ok, ref, numstat(out)}

        {:ok, %{err: err}} when ref == "HEAD" ->
          if unborn?(err), do: unborn_stat(root, args, paths, env), else: :error

        _ ->
          :error
      end

    case stat do
      {:ok, _, []} ->
        empty_diff()

      {:ok, ref, files} ->
        {:ok, %{out: out, truncated: truncated}} =
          Git.run(root, args ++ ["--patch", ref, "--"] ++ paths, env: env, max_bytes: limit)

        %{
          diff: if(truncated, do: out <> @truncated_marker, else: out),
          files: files,
          truncated: truncated
        }

      :error ->
        empty_diff()
    end
  end

  # A repository without commits diffs against the empty tree.
  defp unborn_stat(root, args, paths, env) do
    with {:ok, tree} <- Git.ok(root, ~w(hash-object -t tree /dev/null)),
         tree = String.trim(tree),
         {:ok, out} <-
           Git.ok(root, args ++ ["--numstat", "-z", tree, "--"] ++ paths,
             env: env,
             max_bytes: @metadata_max
           ) do
      {:ok, tree, numstat(out)}
    else
      _ -> :error
    end
  end

  defp unborn?(err) do
    err = String.downcase(err)

    String.contains?(err, "bad revision 'head'") or
      (String.contains?(err, "unknown revision") and
         String.contains?(err, "path not in the working tree"))
  end

  @doc "Parses `git diff --numstat -z` into `ReviewDiffFileStat`s, renames included."
  def numstat(out), do: out |> String.split(<<0>>) |> parse_numstat([]) |> Enum.reverse()

  defp parse_numstat([], acc), do: acc

  defp parse_numstat([field | rest], acc) do
    case Regex.run(~r/^(\d+|-)\t(\d+|-)\t(.*)$/s, field) do
      [_, added, deleted, ""] ->
        case rest do
          [previous, path | rest] ->
            parse_numstat(rest, [stat(path, previous, added, deleted) | acc])

          _ ->
            acc
        end

      [_, added, deleted, path] ->
        parse_numstat(rest, [stat(path, nil, added, deleted) | acc])

      nil ->
        parse_numstat(rest, acc)
    end
  end

  defp stat(path, previous, added, deleted),
    do: %{
      "path" => path,
      "previousPath" => previous,
      "additions" => count(added),
      "deletions" => count(deleted)
    }

  defp count("-"), do: 0
  defp count(n), do: String.to_integer(n)

  defp current_branch(root) do
    case Git.ok(root, ~w(symbolic-ref --short -q HEAD)) do
      {:ok, branch} -> String.trim(branch) |> then(&if(&1 == "", do: nil, else: &1))
      _ -> nil
    end
  end

  # The branch this one merges into: its gh-merge-base, the remote's default
  # branch, then main or master; remote-tracking refs preferred.
  defp base_branch(root, branch) do
    configured = git_line(root, ["config", "--get", "branch.#{branch}.gh-merge-base"])
    remote = primary_remote(root)

    default =
      remote &&
        case git_line(root, ["symbolic-ref", "refs/remotes/#{remote}/HEAD"]) do
          "refs/remotes/" <> rest -> String.replace_prefix(rest, "#{remote}/", "")
          _ -> nil
        end

    [configured, default, "main", "master"]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.map(fn candidate ->
      candidate
      |> String.replace_prefix("origin/", "")
      |> then(
        &if(remote && remote != "origin",
          do: String.replace_prefix(&1, "#{remote}/", ""),
          else: &1
        )
      )
    end)
    |> Enum.reject(&(&1 == "" or &1 == branch))
    |> Enum.find_value(fn candidate ->
      cond do
        remote && ref?(root, "refs/remotes/#{remote}/#{candidate}") -> "#{remote}/#{candidate}"
        ref?(root, "refs/heads/#{candidate}") -> candidate
        true -> nil
      end
    end)
  end

  defp primary_remote(root) do
    case Git.ok(root, ["remote"]) do
      {:ok, out} ->
        remotes = String.split(out, "\n", trim: true)
        if "origin" in remotes, do: "origin", else: List.first(remotes)

      _ ->
        nil
    end
  end

  defp ref?(root, ref),
    do: match?({:ok, _}, Git.ok(root, ["show-ref", "--verify", "--quiet", ref]))

  defp git_line(root, args) do
    case Git.ok(root, args) do
      {:ok, out} -> String.trim(out)
      _ -> nil
    end
  end

  @doc "`review.getDiffFileContents`: both sides of one file, for expanding its diff."
  def file_contents(%{"cwd" => cwd, "sourceKind" => kind} = input) do
    with :ok <- within_projects(cwd, "getDiffFileContents") do
      if kind == "working-tree", do: working_tree_contents(input), else: branch_contents(input)
    end
  end

  defp working_tree_contents(%{"cwd" => cwd} = input) do
    with {:ok, root} <-
           Git.ok(cwd, ~w(rev-parse --show-toplevel))
           |> or_error(input, "Could not resolve the Git repository root."),
         {:ok, old} <-
           side(input, input["changeType"] == "new", fn ->
             at_revision(input, input["baseRef"] || "HEAD", input["oldPath"])
           end),
         {:ok, new} <-
           side(input, input["changeType"] == "deleted", fn ->
             working_file(input, String.trim(root))
           end) do
      {:ok, %{"oldContents" => old, "newContents" => new}}
    end
  end

  defp branch_contents(%{"baseRef" => base, "headRef" => head} = input)
       when is_binary(base) and is_binary(head) do
    with {:ok, merge_base} <-
           Git.ok(input["cwd"], ["merge-base", base, head])
           |> or_error(input, "Could not resolve the branch comparison base."),
         {:ok, old} <-
           side(input, input["changeType"] == "new", fn ->
             at_revision(input, String.trim(merge_base), input["oldPath"])
           end),
         {:ok, new} <-
           side(input, input["changeType"] == "deleted", fn ->
             at_revision(input, head, input["newPath"])
           end) do
      {:ok, %{"oldContents" => old, "newContents" => new}}
    end
  end

  defp branch_contents(input),
    do: {:error, git_error(input, "Branch diff file expansion requires both base and head refs.")}

  defp side(_input, true, _read), do: {:ok, ""}
  defp side(_input, false, read), do: read.()

  defp at_revision(input, revision, path) do
    case Git.run(input["cwd"], ["show", "#{revision}:#{path}"], max_bytes: @file_max) do
      {:ok, %{status: 0, out: out}} ->
        if String.contains?(out, <<0>>),
          do: {:error, git_error(input, "Cannot expand binary file '#{path}'.")},
          else: {:ok, out}

      _ ->
        {:error, git_error(input, "Could not read '#{path}' at #{revision}.")}
    end
  end

  # Only a regular file inside the repository, up to 1 MB of text.
  defp working_file(input, root) do
    path = Path.expand(input["newPath"], root)

    cond do
      not inside?(path, root) ->
        {:error,
         git_error(
           input,
           "Diff file '#{input["newPath"]}' resolves outside the review workspace."
         )}

      true ->
        case File.lstat(path) do
          {:ok, %{type: :regular, size: size}} when size <= @file_max ->
            data = File.read!(path)

            if String.contains?(data, <<0>>),
              do: {:error, git_error(input, "Cannot expand binary file '#{input["newPath"]}'.")},
              else: {:ok, data}

          {:ok, %{type: :regular}} ->
            {:error,
             git_error(input, "Diff file '#{input["newPath"]}' exceeds the 1 MB expansion limit.")}

          _ ->
            {:error, git_error(input, "Diff path '#{input["newPath"]}' is not a file.")}
        end
    end
  end

  defp or_error({:ok, _} = ok, _input, _detail), do: ok
  defp or_error(_, input, detail), do: {:error, git_error(input, detail)}

  defp git_error(input, detail),
    do: %{
      "_tag" => "GitCommandError",
      "operation" => "review.getDiffFileContents",
      "command" => "git",
      "cwd" => input["cwd"],
      "detail" => detail,
      "message" => "Git command failed (#{input["cwd"]}): #{detail}"
    }

  defp within_projects(cwd, operation) do
    cwd = Path.expand(cwd)

    roots =
      for {{node, _}, {"project", %{"workspaceRoot" => root} = project}} <- T3.Shell.rows(),
          node == node() and is_binary(root) and project["deletedAt"] == nil,
          do: Path.expand(root)

    if Enum.any?(roots, &inside?(cwd, &1)) do
      :ok
    else
      detail = "Review cwd must be inside one of this node's projects."

      {:error,
       %{
         "_tag" => "VcsRepositoryDetectionError",
         "operation" => "review.#{operation}",
         "cwd" => cwd,
         "detail" => detail,
         "message" => detail
       }}
    end
  end

  defp inside?(path, root), do: path == root or String.starts_with?(path, root <> "/")

  defp now, do: DateTime.utc_now() |> DateTime.to_iso8601()
end
