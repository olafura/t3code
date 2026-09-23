defmodule T3.WorktreeSetupTest do
  use ExUnit.Case, async: false

  alias T3.{Orchestration, StreamState}

  @moduletag :tmp_dir
  @fake_codex Path.expand("../support/fake_codex.py", __DIR__)

  setup %{tmp_dir: dir} do
    repo = Path.join(dir, "repo")
    File.mkdir_p!(repo)
    git = &System.cmd("git", &1, cd: repo, stderr_to_stdout: true)
    {_, 0} = git.(~w(init -q -b main))
    {_, 0} = git.(~w(-c user.email=t@t -c user.name=t commit -q --allow-empty -m init))

    Application.put_env(:t3, :home, Path.join(dir, "home"))
    Application.put_env(:t3, :codex_command, ["python3", "-u", @fake_codex])
    on_exit(fn -> Application.delete_env(:t3, :codex_command) end)

    start_supervised!(T3.Settings)
    start_supervised!({T3.Store, path: Path.join(dir, "t3.sqlite")})
    start_supervised!(T3.Streams)
    start_supervised!(T3.Shell)
    start_supervised!(T3.Workspace)
    start_supervised!({Registry, keys: :unique, name: T3.Codex.Registry})
    start_supervised!({DynamicSupervisor, name: T3.Codex.Supervisor, strategy: :one_for_one})
    start_supervised!({Registry, keys: :unique, name: T3.Terminal.Registry}, id: :terminals)

    start_supervised!({DynamicSupervisor, name: T3.Terminal.Supervisor, strategy: :one_for_one},
      id: :terminal_sup
    )

    start_supervised!(T3.Terminal.Hub)
    start_supervised!(T3.WorktreeSetup)

    :ok = T3.Shell.subscribe(self())
    %{repo: repo}
  end

  defp project(repo, scripts) do
    {:ok, _} =
      T3.Projects.mutate(%{
        "type" => "project.create",
        "projectId" => "p1",
        "workspaceRoot" => repo
      })

    assert_receive {:t3_shell, {:rows, _, [{"p1", _}]}}, 1_000

    if scripts != [] do
      {:ok, _} =
        T3.Projects.mutate(%{
          "type" => "project.update",
          "projectId" => "p1",
          "scripts" => scripts
        })

      assert_receive {:t3_shell, {:rows, _, [{"p1", {"project", %{"scripts" => [_ | _]}}}]}},
                     1_000
    end
  end

  defp launch(text) do
    thread_id = "thread-#{System.unique_integer([:positive])}"
    :ok = T3.WorktreeSetup.subscribe(thread_id, self()) |> then(fn _ -> :ok end)
    :ok = T3.Streams.subscribe(thread_id, self(), nil)

    {:ok, %{"threadId" => ^thread_id}} =
      Orchestration.launch_thread(%{
        "commandId" => "c",
        "threadId" => thread_id,
        "projectId" => "p1",
        "title" => "Work",
        "modelSelection" => %{"instanceId" => "codex", "model" => "gpt-5.4"},
        "runtimeMode" => "full-access",
        "interactionMode" => "default",
        "workspaceStrategy" => %{"type" => "worktree", "baseRef" => "main"},
        "initialMessage" => %{"messageId" => "m1", "text" => text, "attachments" => []}
      })

    thread_id
  end

  defp await_phase(thread_id, phase) do
    receive do
      {:t3_worktree_setup, ^thread_id, %{"phase" => ^phase} = snapshot} -> snapshot
      {:t3_worktree_setup, ^thread_id, _} -> await_phase(thread_id, phase)
    after
      15_000 -> flunk("setup never reached #{phase}")
    end
  end

  defp current(thread_id), do: T3.Streams.Server.state(T3.Streams.ensure(thread_id))

  test "a thread in a new worktree runs its first turn there", %{repo: repo} do
    project(repo, [])
    thread_id = launch("list the files")
    snapshot = await_phase(thread_id, "done")

    assert %{"worktreePath" => path, "branch" => "t3code/" <> _} = snapshot
    assert File.dir?(path)

    assert Enum.map(snapshot["stages"], &{&1["id"], &1["status"]}) ==
             [
               {"fetch", "skipped"},
               {"checkout", "done"},
               {"setup-script", "skipped"},
               {"agent", "done"}
             ]

    state = await_completed(thread_id)
    assert %{"worktreePath" => ^path} = StreamState.get(state, "thread")[thread_id]
    assert [%{"status" => "completed"}] = StreamState.list(state, "run")
    assert [%{"cwd" => ^path}] = StreamState.list(state, "checkpoint-scope")
  end

  test "a blocking setup script runs in the worktree before the agent", %{repo: repo} do
    project(repo, [
      %{
        "id" => "setup",
        "name" => "Setup",
        "command" => "echo ready > setup.txt",
        "icon" => "configure",
        "runOnWorktreeCreate" => true,
        "async" => false
      }
    ])

    thread_id = launch("list the files")
    snapshot = await_phase(thread_id, "done")

    assert %{"status" => "done", "detail" => "exited with 0"} =
             Enum.find(snapshot["stages"], &(&1["id"] == "setup-script"))

    assert File.read!(Path.join(snapshot["worktreePath"], "setup.txt")) == "ready\n"
  end

  test "cancelling setup removes the worktree and cancels the run", %{repo: repo} do
    project(repo, [
      %{
        "id" => "slow",
        "name" => "Slow",
        "command" => "sleep 30",
        "icon" => "configure",
        "runOnWorktreeCreate" => true,
        "async" => false
      }
    ])

    thread_id = launch("list the files")
    %{"worktreePath" => path} = await_running_script(thread_id)

    assert {:ok, %{"cancelled" => true}} = T3.WorktreeSetup.cancel(%{"threadId" => thread_id})
    await_phase(thread_id, "cancelled")
    refute File.exists?(path)

    state = current(thread_id)
    assert [%{"status" => "cancelled"}] = StreamState.list(state, "run")
    assert %{"worktreePath" => nil} = StreamState.get(state, "thread")[thread_id]
  end

  defp await_running_script(thread_id) do
    receive do
      {:t3_worktree_setup, ^thread_id, %{"setupScript" => %{}} = snapshot} -> snapshot
      {:t3_worktree_setup, ^thread_id, _} -> await_running_script(thread_id)
    after
      15_000 -> flunk("the setup script never started")
    end
  end

  defp await_completed(thread_id) do
    state = current(thread_id)

    if match?([%{"status" => "completed"}], StreamState.list(state, "run")) do
      state
    else
      receive do
        {:t3_stream, ^thread_id, _} -> await_completed(thread_id)
      after
        15_000 -> flunk("the run never completed")
      end
    end
  end
end
