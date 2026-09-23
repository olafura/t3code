defmodule T3.StorageCleanupTest do
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    Application.put_env(:t3, :home, dir)
    Application.put_env(:t3, :storage_cleanup_first_ms, nil)
    on_exit(fn -> Application.delete_env(:t3, :storage_cleanup_first_ms) end)

    start_supervised!({T3.Store, path: Path.join(dir, "t3.sqlite")})
    start_supervised!(T3.Streams)
    start_supervised!(T3.Shell)
    start_supervised!(T3.Settings)
    start_supervised!({Registry, keys: :unique, name: T3.Codex.Registry})
    start_supervised!({Registry, keys: :unique, name: T3.Claude.Registry}, id: :claude)
    start_supervised!({Registry, keys: :unique, name: T3.Acp.Registry}, id: :acp)
    start_supervised!({Registry, keys: :unique, name: T3.Vcs.Registry}, id: :vcs)
    start_supervised!(T3.StorageCleanup)

    # A clone, so the default branch is known (`origin/HEAD`).
    origin = Path.join(dir, "origin.git")
    seed = Path.join(dir, "seed")
    repo = Path.join(dir, "repo")
    git(dir, ~w(init -q --bare -b main) ++ [origin])
    git(dir, ~w(init -q -b main) ++ [seed])
    File.write!(Path.join(seed, "a.txt"), "a\n")
    git(seed, ~w(add .))
    git(seed, ~w(-c user.name=t -c user.email=t@t commit -q -m first))
    git(seed, ["push", "-q", origin, "main"])
    git(dir, ["clone", "-q", origin, repo])

    {:ok, _} =
      T3.Projects.mutate(%{
        "type" => "project.create",
        "projectId" => "p1",
        "title" => "Repo",
        "workspaceRoot" => repo
      })

    %{repo: repo}
  end

  defp git(cwd, args), do: {_, 0} = System.cmd("git", args, cd: cwd, stderr_to_stdout: true)

  defp settings(storage) do
    {_, version} = T3.Settings.get()
    {:ok, _} = T3.Settings.put(%{"storageCleanup" => storage}, version)
  end

  # A thread on its own new worktree, branched from main.
  defp thread(repo, id, extra \\ %{}) do
    {:ok, %{"worktree" => %{"path" => path}}} =
      T3.Vcs.create_worktree(%{"cwd" => repo, "refName" => "main", "newRefName" => "t3/#{id}"})

    :ok = T3.Shell.subscribe(self())

    {:ok, _} =
      T3.Streams.commit(id, :thread, [
        {"thread", id,
         %{
           "s" =>
             Map.merge(
               %{
                 "id" => id,
                 "projectId" => "p1",
                 "title" => id,
                 "branch" => "t3/#{id}",
                 "worktreePath" => path,
                 "createdAt" => "2026-01-01T00:00:00.000Z"
               },
               extra
             )
         }}
      ])

    assert_receive {:t3_shell, {:rows, _, [{^id, _}]}}, 2_000
    path
  end

  test "a worktree whose branch is already in main goes; one with changes stays", %{repo: repo} do
    settings(%{"worktreeUnchanged" => true})
    gone = thread(repo, "th-1")
    kept = thread(repo, "th-2")
    File.write!(Path.join(kept, "a.txt"), "changed\n")

    :ok = T3.StorageCleanup.sweep()

    refute File.exists?(gone)
    assert File.exists?(kept)
    # The thread keeps its branch, so the worktree can come back.
    assert {:ok, _} = T3.Git.ok(repo, ~w(rev-parse --verify t3/th-1))
  end

  test "nothing goes without a rule, and ignored files other than dependencies keep a worktree",
       %{repo: repo} do
    path = thread(repo, "th-3")
    :ok = T3.StorageCleanup.sweep()
    assert File.exists?(path)

    settings(%{"worktreeUnchanged" => true})
    File.write!(Path.join(path, ".gitignore"), ".env\n")
    git(path, ~w(add .gitignore))
    git(path, ~w(-c user.name=t -c user.email=t@t commit -q -m ignore))
    File.write!(Path.join(path, ".env"), "SECRET=1\n")

    :ok = T3.StorageCleanup.sweep()
    assert File.exists?(path)
  end

  test "a deleted thread's worktree goes when that is the rule", %{repo: repo} do
    settings(%{"worktreeOnDelete" => true})
    path = thread(repo, "th-4", %{"deletedAt" => "2026-01-02T00:00:00.000Z"})

    :ok = T3.StorageCleanup.sweep()
    refute File.exists?(path)
  end

  test "a project can turn cleanup off for itself", %{repo: repo} do
    {_, version} = T3.Settings.get()

    {:ok, _} =
      T3.Settings.put(
        %{
          "storageCleanup" => %{"worktreeUnchanged" => true},
          "projectSettingsOverrides" => %{"p1" => %{"worktreeCleanup" => %{"mode" => "off"}}}
        },
        version
      )

    path = thread(repo, "th-5")
    :ok = T3.StorageCleanup.sweep()
    assert File.exists?(path)
  end
end
