defmodule T3.GitActionsTest do
  use ExUnit.Case, async: false

  alias T3.GitActions

  @moduletag :tmp_dir
  @fake_claude Path.expand("../support/fake_claude_text.sh", __DIR__)

  setup %{tmp_dir: dir} do
    previous = Application.get_env(:t3, :text_claude_command)
    Application.put_env(:t3, :text_claude_command, @fake_claude)
    on_exit(fn -> Application.put_env(:t3, :text_claude_command, previous) end)

    origin = Path.join(dir, "origin.git")
    repo = Path.join(dir, "repo")
    git!(dir, ["init", "-q", "--bare", "-b", "main", origin])
    git!(dir, ["clone", "-q", origin, repo])
    git!(repo, ~w(config user.name t))
    git!(repo, ~w(config user.email t@t))
    File.write!(Path.join(repo, "a.txt"), "one\n")
    git!(repo, ~w(add a.txt))
    git!(repo, ~w(commit -q -m init))
    git!(repo, ~w(push -q -u origin main))
    %{repo: repo, origin: origin}
  end

  defp run(input) do
    me = self()
    result = GitActions.run(Map.put(input, "actionId", "a1"), &send(me, {:event, &1}))
    {result, events()}
  end

  defp events(acc \\ []) do
    receive do
      {:event, e} -> events([e | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  test "a commit with the user's message, offering to push next", %{repo: repo} do
    File.write!(Path.join(repo, "b.txt"), "b\n")

    {{:ok, result}, events} =
      run(%{"cwd" => repo, "action" => "commit", "commitMessage" => "Add b\n\nBecause."})

    assert %{"commit" => %{"status" => "created", "subject" => "Add b", "commitSha" => sha}} =
             result

    assert %{
             "title" => "Committed " <> short,
             "cta" => %{"kind" => "run_action", "label" => "Push"}
           } = result["toast"]

    assert String.starts_with?(sha, short)
    assert git!(repo, ~w(log -1 --format=%B)) =~ "Add b\n\nBecause."

    assert [%{"kind" => "action_started", "phases" => ["commit"]} | _] = events
    assert %{"kind" => "action_finished"} = List.last(events)
    # A message was given, so none was generated.
    refute Enum.any?(events, &(&1["label"] == "Generating commit message..."))
  end

  test "commit and push with a generated message", %{repo: repo, origin: origin} do
    File.write!(Path.join(repo, "b.txt"), "b\n")
    {{:ok, result}, events} = run(%{"cwd" => repo, "action" => "commit_push"})

    assert %{
             "commit" => %{"subject" => "Add greeting file"},
             "push" => %{"status" => "pushed", "upstreamBranch" => "origin/main"}
           } = result

    assert Enum.any?(events, &(&1["label"] == "Generating commit message..."))
    assert git!(origin, ~w(log -1 --format=%s main)) == "Add greeting file\n"
  end

  test "a feature branch named by the agent is created and published", %{
    repo: repo,
    origin: origin
  } do
    File.write!(Path.join(repo, "b.txt"), "b\n")

    {{:ok, result}, _} =
      run(%{"cwd" => repo, "action" => "commit_push", "featureBranch" => true})

    assert %{"branch" => %{"status" => "created", "name" => "feature/add-greeting"}} = result

    assert %{
             "push" => %{"setUpstream" => true, "upstreamBranch" => "origin/feature/add-greeting"}
           } = result

    assert git!(origin, ~w(branch --list feature/add-greeting)) =~ "feature/add-greeting"
  end

  test "nothing to commit is not an error; a push without a remote is", %{repo: repo} do
    {{:ok, %{"commit" => %{"status" => "skipped_no_changes"}}}, _} =
      run(%{"cwd" => repo, "action" => "commit"})

    git!(repo, ~w(remote remove origin))
    git!(repo, ~w(checkout -q -b lonely))
    File.write!(Path.join(repo, "c.txt"), "c\n")

    {{:error, message}, events} =
      run(%{"cwd" => repo, "action" => "commit_push", "commitMessage" => "c"})

    assert message =~ "no git remote"
    assert %{"kind" => "action_failed", "phase" => "push"} = List.last(events)
  end

  test "feature branch names" do
    assert GitActions.feature_branch_name("Add Login Form!") == "feature/add-login-form"
    assert GitActions.feature_branch_name("feature/x y") == "feature/x-y"
    assert GitActions.feature_branch_name("...") == "feature/update"
  end

  defp git!(dir, args) do
    {out, 0} = System.cmd("git", args, cd: dir, stderr_to_stdout: true)
    out
  end
end
