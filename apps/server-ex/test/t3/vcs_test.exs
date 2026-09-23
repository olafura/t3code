defmodule T3.VcsTest do
  use ExUnit.Case, async: false

  alias T3.Vcs

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    Application.put_env(:t3, :home, Path.join(dir, "home"))
    start_supervised!({Registry, keys: :unique, name: T3.Vcs.Registry})
    start_supervised!({DynamicSupervisor, name: T3.Vcs.Supervisor, strategy: :one_for_one})

    origin = Path.join(dir, "origin.git")
    repo = Path.join(dir, "repo")
    other = Path.join(dir, "other")
    git!(dir, ["init", "-q", "--bare", "-b", "main", origin])
    git!(dir, ["clone", "-q", origin, repo])
    File.write!(Path.join(repo, "a.txt"), "one\n")
    git!(repo, ~w(add a.txt))
    commit!(repo, "init")
    git!(repo, ~w(push -q -u origin main))
    git!(repo, ~w(remote set-head origin main))
    git!(dir, ["clone", "-q", origin, other])
    %{repo: repo, other: other}
  end

  test "local status lists every change with its line counts", %{repo: repo} do
    File.write!(Path.join(repo, "a.txt"), "one\ntwo\n")
    File.write!(Path.join(repo, "staged.txt"), "s\n")
    git!(repo, ~w(add staged.txt))
    File.write!(Path.join(repo, "new file.txt"), "n\n")

    assert %{
             "isRepo" => true,
             "refName" => "main",
             "isDefaultRef" => true,
             "hasPrimaryRemote" => true,
             "hasWorkingTreeChanges" => true,
             "workingTree" => %{"files" => files, "insertions" => 2, "deletions" => 0}
           } = Vcs.local_status(repo)

    assert Enum.map(files, &{&1["path"], &1["insertions"]}) == [
             {"a.txt", 1},
             {"new file.txt", 0},
             {"staged.txt", 1}
           ]

    # The tmp dir sits inside this checkout, so use the system temp dir.
    plain = Path.join(System.tmp_dir!(), "t3-not-a-repo-#{System.unique_integer([:positive])}")
    File.mkdir_p!(plain)
    on_exit(fn -> File.rm_rf!(plain) end)
    assert %{"isRepo" => false} = Vcs.local_status(plain)
  end

  test "ahead and behind, after a fetch", %{repo: repo, other: other} do
    File.write!(Path.join(other, "b.txt"), "b\n")
    git!(other, ~w(add b.txt))
    commit!(other, "from other")
    git!(other, ~w(push -q))

    File.write!(Path.join(repo, "c.txt"), "c\n")
    git!(repo, ~w(add c.txt))
    commit!(repo, "local")

    assert %{"hasUpstream" => true, "aheadCount" => 1, "behindCount" => 0} =
             Vcs.remote_status(repo)

    assert {:ok, %{"aheadCount" => 1, "behindCount" => 1, "refName" => "main"}} =
             Vcs.refresh_status(%{"cwd" => repo})
  end

  test "refs: current first, remote mirrors hidden, remote-only branches trackable", %{
    repo: repo,
    other: other
  } do
    git!(other, ~w(checkout -q -b remote-only))
    git!(other, ~w(push -q -u origin remote-only))
    git!(repo, ~w(fetch -q))

    {:ok, %{"refName" => "feature"}} =
      Vcs.create_ref(%{"cwd" => repo, "refName" => "feature", "switchRef" => true})

    assert {:ok, %{"refs" => refs, "isRepo" => true, "totalCount" => 3}} =
             Vcs.list_refs(%{"cwd" => repo})

    assert [%{"name" => "feature", "current" => true} | _] = refs
    names = Enum.map(refs, & &1["name"])
    assert "main" in names and "origin/remote-only" in names
    refute "origin/main" in names

    assert {:ok, %{"refs" => [%{"name" => "origin/remote-only"}]}} =
             Vcs.list_refs(%{"cwd" => repo, "refKind" => "remote", "query" => "ONLY"})

    # Switching to a remote ref checks out a local branch tracking it.
    assert {:ok, %{"refName" => "remote-only"}} =
             Vcs.switch_ref(%{"cwd" => repo, "refName" => "origin/remote-only"})

    assert %{"hasUpstream" => true} = Vcs.remote_status(repo)
  end

  test "pull fast-forwards, and says when there is nothing to pull", %{repo: repo, other: other} do
    assert {:ok, %{"status" => "skipped_up_to_date"}} = Vcs.pull(%{"cwd" => repo})

    File.write!(Path.join(other, "b.txt"), "b\n")
    git!(other, ~w(add b.txt))
    commit!(other, "from other")
    git!(other, ~w(push -q))

    assert {:ok, %{"status" => "pulled", "refName" => "main", "upstreamRef" => "origin/main"}} =
             Vcs.pull(%{"cwd" => repo})

    assert File.exists?(Path.join(repo, "b.txt"))
  end

  test "worktrees are created under the T3 home and removed again", %{repo: repo, tmp_dir: dir} do
    assert {:ok, %{"worktree" => %{"path" => path, "refName" => "wt/branch"}}} =
             Vcs.create_worktree(%{
               "cwd" => repo,
               "refName" => "main",
               "newRefName" => "wt/branch",
               "path" => nil
             })

    assert path == Path.join([dir, "home", "worktrees", "repo", "wt-branch"])
    assert File.exists?(Path.join(path, "a.txt"))

    assert {:ok, %{"refs" => refs}} = Vcs.list_refs(%{"cwd" => repo})
    assert %{"worktreePath" => ^path} = Enum.find(refs, &(&1["name"] == "wt/branch"))

    assert {:ok, nil} = Vcs.remove_worktree(%{"cwd" => repo, "path" => path})
    refute File.exists?(path)
    # Already gone is not an error.
    assert {:ok, nil} = Vcs.remove_worktree(%{"cwd" => repo, "path" => path})
  end

  test "watchers get a snapshot, then only what changed", %{repo: repo} do
    assert %{"_tag" => "snapshot", "local" => %{"hasWorkingTreeChanges" => false}} =
             T3.Vcs.Watch.subscribe(repo, self())

    File.write!(Path.join(repo, "a.txt"), "changed\n")
    :ok = T3.Vcs.Watch.refresh(repo)

    assert_receive {:t3_vcs, ^repo,
                    %{"_tag" => "localUpdated", "local" => %{"hasWorkingTreeChanges" => true}}},
                   2_000

    # Nothing changed, so nothing is sent.
    :ok = T3.Vcs.Watch.refresh(repo)
    refute_receive {:t3_vcs, _, _}, 200
  end

  defp commit!(repo, message),
    do: git!(repo, ~w(-c user.name=t -c user.email=t@t commit -q -m) ++ [message])

  defp git!(dir, args) do
    {out, 0} = System.cmd("git", args, cd: dir, stderr_to_stdout: true)
    out
  end
end
