defmodule T3.GitActions do
  @moduledoc """
  `git.runStackedAction`: commit, push, and open a pull request, in any stacked
  combination, reporting `GitActionProgressEvent`s as each phase runs.

  A missing commit message is written by a coding agent (`T3.TextGeneration`), as
  is a feature branch name when one is asked for. Pull requests are GitHub's, via
  the `gh` CLI: an open one for the branch is reused, otherwise one is created
  with a generated title and body.

  `start/2` runs an action in its own process and sends each event to the
  subscriber as `{:t3_git_action, action_id, event}`.
  """

  alias T3.{Git, TextGeneration, Vcs}

  @commit_actions ~w(commit commit_push commit_push_pr)

  @doc "Runs the action (`GitRunStackedActionInput`) in a new process."
  def start(%{"actionId" => action_id} = input, subscriber) do
    {:ok, _} =
      Task.start(fn ->
        emit = fn event ->
          send(subscriber, {:t3_git_action, action_id, event_base(input) |> Map.merge(event)})
        end

        run(input, emit)
      end)

    :ok
  end

  defp event_base(input),
    do: %{"actionId" => input["actionId"], "cwd" => input["cwd"], "action" => input["action"]}

  @doc "Runs the action, calling `emit` with each progress event; returns the result or an error."
  def run(%{"cwd" => cwd} = input, emit) do
    # The phase running when an error is thrown, for the failure event.
    Process.put(:git_action_phase, nil)

    try do
      result = run_action(input, emit)
      emit.(%{"kind" => "action_finished", "result" => result})
      {:ok, result}
    catch
      {:git_action_error, message} ->
        emit.(%{
          "kind" => "action_failed",
          "phase" => Process.get(:git_action_phase),
          "message" => message
        })

        {:error, message}
    after
      Vcs.Watch.refresh(cwd)
    end
  end

  defp fail!(message), do: throw({:git_action_error, message})

  defp phase!(emit, phase, label) do
    Process.put(:git_action_phase, phase)
    emit.(%{"kind" => "phase_started", "phase" => phase, "label" => label})
  end

  defp run_action(%{"cwd" => cwd, "action" => action} = input, emit) do
    status = Map.merge(Vcs.local_status(cwd), Vcs.remote_status(cwd) || %{})
    branch = status["refName"]
    commit? = action in @commit_actions
    feature? = input["featureBranch"] == true

    push? =
      action in ~w(push commit_push commit_push_pr) or
        (action == "create_pr" and (not status["hasUpstream"] or status["aheadCount"] > 0))

    pr? = action in ~w(create_pr commit_push_pr)

    cond do
      not status["isRepo"] ->
        fail!("#{cwd} is not a git repository.")

      feature? and not commit? ->
        fail!("Feature-branch checkout is only supported for commit actions.")

      action == "create_pr" and status["hasWorkingTreeChanges"] ->
        fail!("Commit local changes before creating a PR.")

      true ->
        :ok
    end

    phases =
      for {wanted, phase} <- [
            {feature?, "branch"},
            {commit?, "commit"},
            {push?, "push"},
            {pr?, "pr"}
          ],
          wanted,
          do: phase

    emit.(%{"kind" => "action_started", "phases" => phases})

    if not feature? and (push? or pr?) and branch == nil,
      do: fail!("Cannot #{if pr?, do: "create a pull request", else: "push"} from detached HEAD.")

    {branch_step, branch, suggestion} =
      if feature? do
        phase!(emit, "branch", "Preparing feature branch...")
        feature_branch(cwd, branch, input)
      else
        {%{"status" => "skipped_not_requested"}, branch, nil}
      end

    commit_step =
      if commit?,
        do: commit(cwd, branch, input, suggestion, emit),
        else: %{"status" => "skipped_not_requested"}

    push_step =
      if push? do
        phase!(emit, "push", "Pushing...")
        push(cwd, branch)
      else
        %{"status" => "skipped_not_requested"}
      end

    pr_step =
      if pr? do
        phase!(emit, "pr", "Preparing PR...")
        pull_request(cwd, branch)
      else
        %{"status" => "skipped_not_requested"}
      end

    result = %{
      "action" => action,
      "branch" => branch_step,
      "commit" => commit_step,
      "push" => push_step,
      "pr" => pr_step
    }

    Map.put(result, "toast", toast(cwd, result))
  end

  # --- steps ----------------------------------------------------------------------

  defp feature_branch(cwd, branch, input) do
    suggestion =
      suggestion(cwd, branch, input, true) ||
        fail!("Cannot create a feature branch because there are no changes to commit.")

    existing =
      case Git.ok(cwd, ~w(branch --list --no-column --format=%\(refname:short\))) do
        {:ok, out} -> out |> String.split("\n", trim: true) |> MapSet.new(&String.downcase/1)
        _ -> MapSet.new()
      end

    name =
      unique_branch(existing, feature_branch_name(suggestion["branch"] || suggestion["subject"]))

    git!(cwd, ["checkout", "-b", name])
    {%{"status" => "created", "name" => name}, name, suggestion}
  end

  defp commit(cwd, branch, input, suggestion, emit) do
    if suggestion == nil and blank?(input["commitMessage"]),
      do: phase!(emit, "commit", "Generating commit message...")

    case suggestion || suggestion(cwd, branch, input, false) do
      nil ->
        %{"status" => "skipped_no_changes"}

      %{"subject" => subject, "body" => body} ->
        phase!(emit, "commit", "Committing...")
        args = ["commit", "-m", subject] ++ if(body == "", do: [], else: ["-m", body])

        case Git.run(cwd, args, max_bytes: 256 * 1024) do
          {:ok, %{status: 0, out: out}} ->
            hook_output(out, emit)
            {:ok, sha} = Git.ok(cwd, ~w(rev-parse HEAD))
            %{"status" => "created", "commitSha" => String.trim(sha), "subject" => subject}

          {:ok, %{out: out, err: err}} ->
            hook_output(out <> err, emit)
            fail!("git commit failed: #{last_lines(err)}")
        end
    end
  end

  # Hooks print to the commit's output; show it the way the Node server does.
  defp hook_output(text, emit) do
    for line <- String.split(text, "\n"), (line = String.trim(line)) != "" do
      emit.(%{"kind" => "hook_output", "hookName" => nil, "stream" => "stderr", "text" => line})
    end
  end

  # Stages the chosen files (or everything) and writes the message; nil when
  # nothing is staged.
  defp suggestion(cwd, branch, input, include_branch) do
    case input["filePaths"] do
      [_ | _] = paths ->
        Git.run(cwd, ["reset"])
        git!(cwd, ["--literal-pathspecs", "add", "-A", "--"] ++ paths)

      _ ->
        git!(cwd, ["add", "-A"])
    end

    {:ok, summary} = Git.ok(cwd, ~w(diff --cached --name-status))

    if String.trim(summary) == "" do
      nil
    else
      case custom_message(input["commitMessage"]) do
        {subject, body} ->
          %{"subject" => subject, "body" => body}
          |> then(&if(include_branch, do: Map.put(&1, "branch", subject), else: &1))

        nil ->
          {:ok, %{out: patch}} =
            Git.run(cwd, ~w(diff --no-ext-diff --cached --patch --minimal), max_bytes: 200_000)

          case TextGeneration.commit_message(cwd, branch, summary, patch, include_branch) do
            {:ok, %{"subject" => subject} = generated} ->
              Map.merge(generated, %{
                "subject" => commit_subject(subject),
                "body" => String.trim(generated["body"] || "")
              })

            {:error, reason} ->
              fail!("Could not write a commit message: #{reason}")
          end
      end
    end
  end

  defp custom_message(nil), do: nil

  defp custom_message(message) do
    case message |> String.replace("\r\n", "\n") |> String.trim() |> String.split("\n") do
      [""] -> nil
      [subject | rest] -> {String.trim(subject), rest |> Enum.join("\n") |> String.trim()}
    end
  end

  defp commit_subject(raw) do
    subject =
      raw
      |> String.trim()
      |> String.split(~r/\r?\n/)
      |> hd()
      |> String.replace(~r/\.+$/, "")
      |> String.trim()

    if subject == "",
      do: "Update project files",
      else: subject |> String.slice(0, 72) |> String.trim_trailing()
  end

  defp push(cwd, branch) do
    status = Vcs.remote_status(cwd) || %{}
    upstream = upstream(cwd)

    cond do
      upstream && status["aheadCount"] == 0 && status["behindCount"] == 0 ->
        %{"status" => "skipped_up_to_date", "branch" => branch, "upstreamBranch" => upstream}

      upstream ->
        git!(cwd, ["push"])
        %{"status" => "pushed", "branch" => branch, "upstreamBranch" => upstream}

      remote = Git.primary_remote(cwd) ->
        git!(cwd, ["push", "-u", remote, "HEAD:refs/heads/#{branch}"])

        %{
          "status" => "pushed",
          "branch" => branch,
          "upstreamBranch" => "#{remote}/#{branch}",
          "setUpstream" => true
        }

      true ->
        fail!("Cannot push because no git remote is configured for this repository.")
    end
  end

  defp upstream(cwd) do
    case Git.ok(cwd, ~w(rev-parse --abbrev-ref --symbolic-full-name @{upstream})) do
      {:ok, ref} -> String.trim(ref)
      _ -> nil
    end
  end

  # GitHub pull requests through `gh`: the open one for this branch, or a new one.
  defp pull_request(cwd, branch) do
    gh = System.find_executable("gh") || fail!("Creating a PR needs the GitHub CLI (gh).")

    base =
      (Git.base_branch(cwd, branch) || "main")
      |> String.replace(~r{^[^/]+/}, "", global: false)
      |> then(&if(&1 == branch, do: "main", else: &1))

    case gh_json(
           gh,
           cwd,
           ~w(pr list --state open --limit 1 --json number,title,url,baseRefName,headRefName --head) ++
             [branch]
         ) do
      [%{"url" => url} = pr | _] ->
        %{
          "status" => "opened_existing",
          "url" => url,
          "number" => pr["number"],
          "baseBranch" => pr["baseRefName"],
          "headBranch" => pr["headRefName"],
          "title" => pr["title"]
        }

      _ ->
        range = "#{base_ref(cwd, base)}...HEAD"
        {:ok, commits} = Git.ok(cwd, ["log", "--oneline", String.replace(range, "...", "..")])
        {:ok, %{out: stat}} = Git.run(cwd, ["diff", "--stat", range], max_bytes: 100_000)

        {:ok, %{out: patch}} =
          Git.run(cwd, ["diff", "--no-ext-diff", "--patch", "--minimal", range],
            max_bytes: 200_000
          )

        %{"title" => title, "body" => body} =
          case TextGeneration.pr_content(cwd, base, branch, commits, stat, patch) do
            {:ok, content} -> content
            {:error, reason} -> fail!("Could not write the PR description: #{reason}")
          end

        title = title |> String.trim() |> String.split("\n") |> hd()

        case Exile.stream(
               [
                 gh,
                 "pr",
                 "create",
                 "--base",
                 base,
                 "--head",
                 branch,
                 "--title",
                 title,
                 "--body-file",
                 "-"
               ],
               cd: cwd,
               input: [body],
               stderr: :consume
             )
             |> Enum.reduce({"", ""}, fn
               {:stdout, d}, {o, e} -> {o <> IO.iodata_to_binary(d), e}
               {:stderr, d}, {o, e} -> {o, e <> IO.iodata_to_binary(d)}
               {:exit, _}, acc -> acc
             end) do
          {out, err} ->
            case Regex.run(~r{https://\S+/pull/(\d+)}, out <> err) do
              [url, number] ->
                %{
                  "status" => "created",
                  "url" => url,
                  "number" => String.to_integer(number),
                  "baseBranch" => base,
                  "headBranch" => branch,
                  "title" => title
                }

              nil ->
                fail!("gh pr create failed: #{last_lines(err)}")
            end
        end
    end
  rescue
    error in [Exile.Stream.AbnormalExit] -> fail!("gh failed: #{Exception.message(error)}")
  end

  defp base_ref(cwd, base) do
    remote = Git.primary_remote(cwd)

    if remote &&
         match?({:ok, _}, Git.ok(cwd, ["rev-parse", "--verify", "--quiet", "#{remote}/#{base}"])),
       do: "#{remote}/#{base}",
       else: base
  end

  defp gh_json(gh, cwd, args) do
    case System.cmd(gh, args, cd: cwd, stderr_to_stdout: false) do
      {out, 0} -> JSON.decode!(out)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  # --- toast ----------------------------------------------------------------------

  defp toast(cwd, result) do
    %{"commit" => commit, "push" => push, "pr" => pr, "action" => action} = result
    default? = Vcs.local_status(cwd)["isDefaultRef"]
    sha = commit["commitSha"] && String.slice(commit["commitSha"], 0, 7)

    {title, description} =
      cond do
        pr["status"] in ["created", "opened_existing"] ->
          verb = if pr["status"] == "created", do: "Created", else: "Opened"
          {"#{verb} PR#{if pr["number"], do: " ##{pr["number"]}"}", pr["title"]}

        push["status"] == "pushed" ->
          target = push["upstreamBranch"] || push["branch"]
          {"Pushed#{if sha, do: " #{sha}"}#{if target, do: " to #{target}"}", commit["subject"]}

        commit["status"] == "created" ->
          {if(sha, do: "Committed #{sha}", else: "Committed changes"), commit["subject"]}

        true ->
          {"Done", nil}
      end

    cta =
      cond do
        action == "commit" and commit["status"] == "created" ->
          %{"kind" => "run_action", "label" => "Push", "action" => %{"kind" => "push"}}

        pr["url"] ->
          %{"kind" => "open_pr", "label" => "View PR", "url" => pr["url"]}

        action in ~w(push commit_push) and push["status"] == "pushed" and not default? ->
          %{"kind" => "run_action", "label" => "Create PR", "action" => %{"kind" => "create_pr"}}

        true ->
          %{"kind" => "none"}
      end

    %{"title" => title, "cta" => cta}
    |> then(&if(description, do: Map.put(&1, "description", truncate(description)), else: &1))
  end

  defp truncate(text) when byte_size(text) <= 72, do: text
  defp truncate(text), do: String.slice(text, 0, 69) |> String.trim_trailing() |> Kernel.<>("...")

  # --- helpers --------------------------------------------------------------------

  @doc "A `feature/…` branch name from free text."
  def feature_branch_name(raw) do
    fragment =
      raw
      |> String.trim()
      |> String.downcase()
      |> String.replace(~r/['"`]/, "")
      |> String.replace(~r{^[./\s_-]+|[./\s_-]+$}, "")
      |> String.replace(~r{[^a-z0-9/_-]+}, "-")
      |> String.replace(~r{/+}, "/")
      |> String.replace(~r/-+/, "-")
      |> String.replace(~r{^[./_-]+|[./_-]+$}, "")
      |> String.slice(0, 64)
      |> String.replace(~r{[./_-]+$}, "")
      |> then(&if(&1 == "", do: "update", else: &1))

    if String.starts_with?(fragment, "feature/"), do: fragment, else: "feature/#{fragment}"
  end

  defp unique_branch(existing, name) do
    if MapSet.member?(existing, name),
      do:
        Enum.find_value(
          Stream.iterate(2, &(&1 + 1)),
          &(not MapSet.member?(existing, "#{name}-#{&1}") && "#{name}-#{&1}")
        ),
      else: name
  end

  defp git!(cwd, args) do
    case Git.run(cwd, args, max_bytes: 256 * 1024) do
      {:ok, %{status: 0}} -> :ok
      {:ok, %{err: err}} -> fail!("git #{hd(args)} failed: #{last_lines(err)}")
      {:error, reason} -> fail!("git #{hd(args)} failed: #{reason}")
    end
  end

  defp last_lines(text),
    do: text |> String.trim() |> String.split("\n") |> Enum.take(-3) |> Enum.join(" ")

  defp blank?(nil), do: true
  defp blank?(text), do: String.trim(text) == ""
end
