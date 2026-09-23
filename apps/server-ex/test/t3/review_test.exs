defmodule T3.ReviewTest do
  use ExUnit.Case, async: false

  alias T3.Review

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    start_supervised!({T3.Store, path: Path.join(dir, "t3.sqlite")})
    start_supervised!(T3.Streams)
    start_supervised!(T3.Shell)

    repo = Path.join(dir, "repo")
    File.mkdir_p!(repo)
    git!(repo, ~w(init -q -b main))
    File.write!(Path.join(repo, "a.txt"), "one\n")
    git!(repo, ~w(add a.txt))
    commit!(repo, "init")
    git!(repo, ~w(checkout -q -b feature))
    File.write!(Path.join(repo, "b.txt"), "b\n")
    git!(repo, ~w(add b.txt))
    commit!(repo, "feature")

    :ok = T3.Shell.subscribe(self())

    {:ok, _} =
      T3.Projects.mutate(%{
        "type" => "project.create",
        "projectId" => "p1",
        "workspaceRoot" => repo
      })

    assert_receive {:t3_shell, {:rows, _, [{"p1", _}]}}, 1_000
    %{repo: repo}
  end

  test "the dirty worktree and the branch against main, untracked files included", %{repo: repo} do
    File.write!(Path.join(repo, "a.txt"), "one\ntwo\n")
    File.write!(Path.join(repo, "new.txt"), "fresh\n")

    assert {:ok, %{"sources" => [dirty, branch]}} = Review.diff_preview(%{"cwd" => repo})

    assert %{"kind" => "working-tree", "baseRef" => "HEAD", "truncated" => false} = dirty

    assert Enum.map(dirty["files"], &{&1["path"], &1["additions"]}) == [
             {"a.txt", 1},
             {"new.txt", 1}
           ]

    assert dirty["diff"] =~ "+++ b/new.txt"

    assert %{"baseRef" => "main", "headRef" => "feature", "title" => "Against main"} = branch
    assert [%{"path" => "b.txt"}] = branch["files"]

    # The untracked file was only added to a scratch index.
    assert git!(repo, ~w(status --porcelain)) =~ "?? new.txt"

    assert {:ok, %{"oldContents" => "", "newContents" => "fresh\n"}} =
             Review.file_contents(%{
               "cwd" => repo,
               "sourceKind" => "working-tree",
               "changeType" => "new",
               "baseRef" => "HEAD",
               "headRef" => nil,
               "oldPath" => "new.txt",
               "newPath" => "new.txt"
             })

    assert {:ok, %{"oldContents" => "", "newContents" => "b\n"}} =
             Review.file_contents(%{
               "cwd" => repo,
               "sourceKind" => "branch-range",
               "changeType" => "new",
               "baseRef" => "main",
               "headRef" => "feature",
               "oldPath" => "b.txt",
               "newPath" => "b.txt"
             })
  end

  test "only this node's projects can be reviewed", %{tmp_dir: dir} do
    assert {:error, %{"_tag" => "VcsRepositoryDetectionError"}} =
             Review.diff_preview(%{"cwd" => dir})
  end

  test "numstat keeps renames' previous paths" do
    assert [%{"path" => "new.ex", "previousPath" => "old.ex", "additions" => 2}] =
             Review.numstat("2\t0\t\u0000old.ex\u0000new.ex\u0000")
  end

  defp commit!(repo, message),
    do: git!(repo, ~w(-c user.name=t -c user.email=t@t commit -q -m) ++ [message])

  defp git!(dir, args) do
    {out, 0} = System.cmd("git", args, cd: dir)
    out
  end
end
