defmodule T3.Checkpoint do
  @moduledoc """
  Workspace checkpoints: a hidden git commit per finished run, under
  `refs/t3/orchestration-v2/checkpoints/…`, so a client can diff what each turn changed.

  A thread has one root checkpoint scope. Ordinal 0 of the scope is the workspace
  before the first run; ordinal `n` is the workspace after run `n`. Scope ids,
  checkpoint ids, and refs are the ones the Node server derives, so threads imported
  from it keep their diffs.

  Captures stage the whole worktree into a private index next to the repository's
  own, so the user's staging area is never touched.
  """

  alias T3.Orchestration.Entities

  @refs_prefix "refs/t3/orchestration-v2/checkpoints"
  @diff_max_bytes 10_000_000
  @identity [
    {"GIT_AUTHOR_NAME", "T3 Code"},
    {"GIT_AUTHOR_EMAIL", "t3code@users.noreply.github.com"},
    {"GIT_COMMITTER_NAME", "T3 Code"},
    {"GIT_COMMITTER_EMAIL", "t3code@users.noreply.github.com"}
  ]
  # Flush objects and refs before publishing them; an unclean restart must not leave
  # empty ref files that break every later fetch.
  @durable ~w(-c core.fsync=objects,reference -c core.fsyncMethod=fsync)
  @index_config ~w(-c core.fsmonitor=false -c sparse.expectFilesOutsideOfPatterns=false)

  @doc "The id of a thread's root checkpoint scope."
  def scope_id(thread_id), do: "checkpoint-scope:thread:#{uri(thread_id)}:name:root"

  @doc "The id of the checkpoint at `ordinal` in a scope."
  def checkpoint_id(scope_id, ordinal), do: "checkpoint:scope:#{uri(scope_id)}:name:#{ordinal}"

  @doc "The git ref holding the checkpoint at `ordinal` in a scope."
  def ref(scope_id, ordinal) do
    key = :crypto.hash(:sha256, scope_id) |> Base.encode16(case: :lower) |> binary_part(0, 32)
    "#{@refs_prefix}/#{Base.url_encode64(key, padding: false)}/ordinal/#{ordinal}"
  end

  defp uri(part), do: URI.encode(part, &URI.char_unreserved?/1)

  @doc "A new root scope entity (`OrchestrationV2CheckpointScope`) for a thread."
  def scope(thread_id, run_id, node_id, provider_thread_id, cwd, at) do
    %{
      "id" => scope_id(thread_id),
      "threadId" => thread_id,
      "runId" => run_id,
      "nodeId" => node_id,
      "parentScopeId" => nil,
      "providerThreadId" => provider_thread_id,
      "kind" => "root_run",
      "ordinalWithinParent" => 0,
      "advancesAppRunCount" => true,
      "cwd" => cwd,
      "createdAt" => at
    }
  end

  @doc """
  Captures the workspace before run `ordinal + 1` unless that checkpoint exists, so
  the run's diff has a starting point. Failures are logged; the run goes ahead.
  """
  def baseline(cwd, scope_id, ordinal) do
    ref = ref(scope_id, ordinal)

    with true <- repo?(cwd),
         false <- exists?(cwd, ref),
         {:error, reason} <- capture(cwd, ref) do
      require Logger
      Logger.warning("checkpoint baseline failed in #{cwd}: #{inspect(reason)}")
    end

    :ok
  end

  @doc """
  Captures the workspace after run `ordinal` and returns its checkpoint entity
  (`OrchestrationV2Checkpoint`), with the files changed since the previous one.
  """
  def capture_run(cwd, scope_id, ordinal, run_id, node_id, thread_id, at) do
    ref = ref(scope_id, ordinal)
    previous = ref(scope_id, max(ordinal - 1, 0))

    {status, files} =
      cond do
        not repo?(cwd) ->
          {"missing", []}

        capture(cwd, ref) != :ok ->
          {"error", []}

        exists?(cwd, previous) ->
          case git(
                 cwd,
                 ~w(diff --numstat -z --no-color --no-ext-diff --no-textconv) ++
                   ["#{previous}^{commit}", "#{ref}^{commit}"]
               ) do
            {:ok, numstat} -> {"ready", numstat_files(numstat)}
            {:error, _} -> {"ready", []}
          end

        true ->
          {"ready", []}
      end

    %{
      "id" => checkpoint_id(scope_id, ordinal),
      "threadId" => thread_id,
      "scopeId" => scope_id,
      "runId" => run_id,
      "nodeId" => node_id,
      "parentCheckpointId" => if(ordinal > 0, do: checkpoint_id(scope_id, ordinal - 1)),
      "ordinalWithinScope" => ordinal,
      "appRunOrdinal" => ordinal,
      "ref" => ref,
      "status" => status,
      "files" => files,
      "capturedAt" => at || Entities.now()
    }
  end

  @doc """
  The patch between two turn counts of a thread (`orchestration.getTurnDiff`): turn 0
  is the workspace before the first run. `state` is the thread's `T3.StreamState`.
  """
  def turn_diff(state, thread_id, from, to, ignore_whitespace \\ true)

  def turn_diff(_state, thread_id, same, same, _ignore_whitespace),
    do: {:ok, diff_result(thread_id, same, same, "")}

  def turn_diff(state, thread_id, from, to, ignore_whitespace) do
    completed =
      for run <- T3.StreamState.list(state, "run"),
          run["status"] == "completed",
          into: MapSet.new(),
          do: run["id"]

    ready =
      for checkpoint <- T3.StreamState.list(state, "checkpoint"),
          checkpoint["status"] == "ready",
          is_integer(checkpoint["appRunOrdinal"]),
          MapSet.member?(completed, checkpoint["runId"]),
          into: %{},
          do: {checkpoint["appRunOrdinal"], checkpoint}

    scopes = T3.StreamState.get(state, "checkpoint-scope")
    root = Enum.find(Map.values(scopes), &(&1["kind"] == "root_run"))

    with {:to, %{} = to_checkpoint} <- {:to, ready[to]},
         {:scope, %{"cwd" => cwd}} <- {:scope, scopes[to_checkpoint["scopeId"]]},
         {:from, from_ref} when is_binary(from_ref) <-
           {:from, if(from == 0, do: root && ref(root["id"], 0), else: ready[from]["ref"])},
         {:ok, diff} <-
           git(
             cwd,
             ~w(diff --patch --no-color --no-ext-diff --no-textconv --src-prefix=a/ --dst-prefix=b/) ++
               if(ignore_whitespace, do: ["--ignore-all-space"], else: []) ++
               ["#{from_ref}^{commit}", "#{to_checkpoint["ref"]}^{commit}"],
             max_bytes: @diff_max_bytes
           ) do
      {:ok, diff_result(thread_id, from, to, diff)}
    else
      {:to, nil} -> {:error, "turn #{to} has no checkpoint"}
      {:scope, _} -> {:error, "the checkpoint's workspace is unknown"}
      {:from, _} -> {:error, "turn #{from} has no checkpoint"}
      {:error, reason} -> {:error, "git diff failed: #{inspect(reason)}"}
    end
  end

  defp diff_result(thread_id, from, to, diff),
    do: %{"threadId" => thread_id, "fromTurnCount" => from, "toTurnCount" => to, "diff" => diff}

  @doc "Whether `cwd` is inside a git worktree."
  def repo?(cwd),
    do: File.dir?(cwd) and git(cwd, ~w(rev-parse --is-inside-work-tree)) == {:ok, "true\n"}

  @doc "Whether a checkpoint ref resolves to a commit."
  def exists?(cwd, ref),
    do: match?({:ok, _}, git(cwd, ["rev-parse", "--verify", "--quiet", "#{ref}^{commit}"]))

  @doc "Commits the whole worktree (tracked and untracked, minus ignored) to `ref`."
  def capture(cwd, ref) do
    with {:ok, common} <- git(cwd, ~w(rev-parse --path-format=absolute --git-common-dir)) do
      index = Path.join(String.trim(common), "t3-checkpoint-index-#{Entities.new_id("i")}")
      env = [{"GIT_INDEX_FILE", index} | @identity]

      try do
        with :ok <- seed_index(cwd, index, env),
             {:ok, _} <- git(cwd, @index_config ++ @durable ++ ~w(add -A -- .), env: env),
             {:ok, tree} <- git(cwd, @index_config ++ @durable ++ ["write-tree"], env: env),
             {:ok, commit} <-
               git(
                 cwd,
                 @durable ++ ["commit-tree", String.trim(tree), "-m", "t3 checkpoint ref=#{ref}"],
                 env: env
               ),
             {:ok, _} <- git(cwd, @durable ++ ["update-ref", ref, String.trim(commit)]) do
          :ok
        end
      after
        File.rm(index)
        File.rm(index <> ".lock")
      end
    end
  end

  # Starts the private index at HEAD. Copying the repository's own index keeps its
  # stat data, so `git add` rehashes only changed files instead of the whole tree.
  defp seed_index(cwd, index, env) do
    cond do
      not match?({:ok, _}, git(cwd, ~w(rev-parse --verify --quiet HEAD^{commit}))) ->
        :ok

      git(cwd, ~w(config --bool core.sparseCheckout)) == {:ok, "true\n"} ->
        # Rebuilding a non-cone sparse index would record exclusions as deletions.
        if git(cwd, ~w(config --bool core.sparseCheckoutCone)) == {:ok, "true\n"},
          do:
            ok(
              git(cwd, @index_config ++ ~w(-c index.sparse=true read-tree --reset HEAD), env: env)
            ),
          else: {:error, :non_cone_sparse_checkout}

      reuse_index(cwd, index, env) ->
        :ok

      true ->
        File.rm(index)
        ok(git(cwd, ~w(read-tree HEAD), env: env))
    end
  end

  defp reuse_index(cwd, index, env) do
    with {:ok, path} <- git(cwd, ~w(rev-parse --path-format=absolute --git-path index)),
         path = String.trim(path),
         {:ok, %{mtime: mtime}} <- File.stat(path, time: :posix),
         # Stay below the source timestamp to keep git's racy-entry check.
         time when time > 0 <- mtime - 1,
         :ok <- File.cp(path, index),
         {:ok, _} <- git(cwd, @index_config ++ ~w(read-tree --reset HEAD), env: env),
         :ok <- File.touch(index, time),
         {:ok, listing} <- git(cwd, @index_config ++ ~w(ls-files -v -z), env: env) do
      # Assume-unchanged (lowercase tag) or skip-worktree (S) entries would hide real
      # changes from `git add`; those need a fresh index.
      listing
      |> String.split(<<0>>, trim: true)
      |> Enum.all?(fn <<tag, _::binary>> -> tag not in ?a..?z and tag != ?S end)
    else
      _ -> false
    end
  end

  defp ok({:ok, _}), do: :ok
  defp ok(error), do: error

  @doc "Parses `git diff --numstat -z` into file summaries (`OrchestrationV2CheckpointFileSummary`)."
  def numstat_files(numstat) do
    numstat
    |> String.split(<<0>>)
    |> parse_numstat([])
    |> Enum.sort_by(& &1["path"])
  end

  defp parse_numstat([], acc), do: acc

  defp parse_numstat([record | rest], acc) do
    case Regex.run(~r/^(\d+|-)\t(\d+|-)\t(.*)$/s, record) do
      # Renames and copies put the source and destination in the next two records.
      [_, added, deleted, ""] ->
        case rest do
          [_source, dest | rest] -> parse_numstat(rest, add_file(acc, dest, added, deleted))
          _ -> acc
        end

      [_, added, deleted, path] ->
        parse_numstat(rest, add_file(acc, path, added, deleted))

      nil ->
        parse_numstat(rest, acc)
    end
  end

  defp add_file(acc, "", _, _), do: acc

  defp add_file(acc, path, added, deleted),
    do: [
      %{
        "path" => path,
        "kind" => "modified",
        "additions" => count(added),
        "deletions" => count(deleted)
      }
      | acc
    ]

  defp count("-"), do: 0
  defp count(n), do: String.to_integer(n)

  # Runs git in `cwd`. Output past `:max_bytes` is dropped.
  defp git(cwd, args, opts \\ []) do
    max = Keyword.get(opts, :max_bytes, 50_000_000)

    {out, err, status} =
      ["git" | args]
      |> Exile.stream(
        cd: cwd,
        env: Keyword.get(opts, :env, []),
        stderr: :consume,
        ignore_epipe: true
      )
      |> Enum.reduce({[], [], 0, nil}, fn
        {:stdout, data}, {out, err, size, status} when size < max ->
          {[out, data], err, size + IO.iodata_length(data), status}

        {:stdout, _}, acc ->
          acc

        {:stderr, data}, {out, err, size, status} ->
          {out, [err, data], size, status}

        {:exit, status}, {out, err, size, _} ->
          {out, err, size, status}
      end)
      |> then(fn {out, err, _size, status} -> {out, err, status} end)

    case status do
      {:status, 0} ->
        {:ok, IO.iodata_to_binary(out) |> binary_part(0, min(IO.iodata_length(out), max))}

      other ->
        {:error, {other, IO.iodata_to_binary(err) |> String.trim()}}
    end
  rescue
    error -> {:error, Exception.message(error)}
  end
end
