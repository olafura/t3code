defmodule T3.PullRequestSyncTest do
  use ExUnit.Case, async: false

  alias T3.{Orchestration, StreamState}
  alias T3.Orchestration.{Entities, Settlement}
  alias T3.PullRequests.{Discovery, Sync}

  @moduletag :tmp_dir
  @fake_gh Path.expand("../support/fake_gh.py", __DIR__)
  @url "https://github.com/acme/widgets/pull/"

  setup %{tmp_dir: dir} do
    Application.put_env(:t3, :home, dir)
    previous = Application.get_env(:t3, :gh_command)
    Application.put_env(:t3, :gh_command, @fake_gh)
    System.put_env("FAKE_GH_RULES", Path.join(dir, "rules.json"))
    System.put_env("FAKE_GH_LOG", Path.join(dir, "gh.log"))

    on_exit(fn ->
      Application.put_env(:t3, :gh_command, previous)
      System.delete_env("FAKE_GH_RULES")
      System.delete_env("FAKE_GH_LOG")
    end)

    start_supervised!({T3.Store, path: Path.join(dir, "t3.sqlite")})
    start_supervised!(T3.Streams)
    start_supervised!(T3.Shell)
    :ok = T3.Shell.subscribe(self())

    root = Path.join(dir, "p1")
    File.mkdir_p!(root)
    {_, 0} = System.cmd("git", ~w(init -q -b main), cd: root)

    {_, 0} =
      System.cmd("git", ~w(remote add origin https://github.com/acme/widgets.git), cd: root)

    {:ok, _} =
      T3.Projects.mutate(%{
        "type" => "project.create",
        "projectId" => "p1",
        "title" => "p1",
        "workspaceRoot" => root
      })

    await_row("p1", & &1)
    rules!(dir, [])
    %{dir: dir, root: root}
  end

  test "linking twice changes nothing, unlinked stack layers stay as tombstones, and syncs are not activity" do
    id = thread!("t-links")
    {:ok, _} = link(id, 5, "manual")
    before = current(id)

    {:ok, _} = link(id, 5, "agent", "#{@url}5?again")
    assert current(id).seq == before.seq
    assert [%{"source" => "manual", "url" => "#{@url}5"}] = pull_requests(id)

    snapshot = %{"state" => "open", "title" => "PR 5", "syncedAt" => Entities.now()}
    stack = %{"kind" => "native", "id" => "9", "layers" => [%{"number" => 5}, %{"number" => 6}]}
    {:ok, _} = sync_link(id, 5, snapshot, stack)
    assert current(id).updated_at == before.updated_at
    assert thread(id)["updatedAt"] == StreamState.get(before, "thread")[id]["updatedAt"]
    assert [%{"snapshot" => ^snapshot, "stack" => ^stack}] = pull_requests(id)

    # A layer of the stack is a tombstone once unlinked; only a user or agent brings it back.
    {:ok, _} = link(id, 6, "stack")
    {:ok, _} = unlink(id, 6)
    assert [_, %{"number" => 6, "source" => "stack-dismissed"}] = pull_requests(id)
    {:ok, _} = link(id, 6, "stack")
    assert [_, %{"number" => 6, "source" => "stack-dismissed"}] = pull_requests(id)
    {:ok, _} = link(id, 6, "manual")
    assert [_, %{"number" => 6, "source" => "manual"}] = pull_requests(id)

    # A pull request outside any stack is simply removed.
    {:ok, _} = link(id, 9, "manual")
    {:ok, _} = unlink(id, 9)
    assert [5, 6] == Enum.map(pull_requests(id), & &1["number"])
  end

  test "a branch pull request is kept only while what it was found from holds", %{root: root} do
    id = thread!("t-branch", %{"branch" => "feature-5"})
    before = current(id)

    found = %{
      "projectId" => "p1",
      "repository" => "acme/widgets",
      "number" => 5,
      "url" => "#{@url}5"
    }

    expected = %{
      "workspaceRoot" => root,
      "branch" => "feature-5",
      "worktreePath" => nil,
      "linkedPullRequest" => nil,
      "branchPullRequest" => nil
    }

    {:ok, _} = sync_branch(id, expected, found)
    assert thread(id)["branchPullRequest"] == found
    assert current(id).updated_at == before.updated_at

    # Written from a stale view of the thread: refused.
    assert {:error, _} = sync_branch(id, expected, nil)
    assert thread(id)["branchPullRequest"] == found

    # A first manual link keeps the branch's pull request beside it.
    {:ok, _} = link(id, 9, "manual")

    assert [{5, "manual"}, {9, "manual"}] ==
             Enum.map(pull_requests(id), &{&1["number"], &1["source"]})
  end

  test "a thread's branch finds its pull request", %{dir: dir} do
    rules!(dir, [
      %{
        "args" => ["pr list", "--head feature-5"],
        "stdout" => [%{"number" => 5, "url" => "#{@url}5", "state" => "OPEN"}]
      }
    ])

    id = thread!("t-discover", %{"branch" => "feature-5"})
    start_supervised!({Discovery, interval: nil})
    :ok = Discovery.sweep()

    assert thread(id)["branchPullRequest"] == %{
             "projectId" => "p1",
             "repository" => "acme/widgets",
             "number" => 5,
             "url" => "#{@url}5"
           }

    # The answer is believed for a while: another sweep does not ask again.
    await_row(id, & &1["branchPullRequest"])
    :ok = Discovery.sweep()
    assert length(calls(dir, "pr list")) == 1
  end

  test "a synced link brings its stack's other layers, but never one the user unlinked", %{
    dir: dir
  } do
    rules!(dir, [summary_rule("OPEN", nil), stack_rule()])
    start_supervised!({Sync, interval: nil})
    id = thread!("t-stack")
    {:ok, _} = link(id, 5, "manual")
    await_row(id, &match?([_], &1["pullRequests"]))

    :ok = Sync.sweep()

    assert [
             %{
               "number" => 5,
               "snapshot" => %{"state" => "open", "title" => "PR"},
               "stack" => stack
             },
             %{"number" => 6, "source" => "stack", "url" => "#{@url}6"}
           ] = pull_requests(id)

    assert %{"kind" => "native", "id" => "42", "layers" => [%{"number" => 5}, %{"number" => 6}]} =
             stack

    {:ok, _} = unlink(id, 6)
    await_row(id, &match?([_, %{"source" => "stack-dismissed"}], &1["pullRequests"]))
    Sync.request(%{"repository" => "acme/widgets", "number" => 5})
    :ok = Sync.sweep()

    assert [%{"number" => 5}, %{"number" => 6, "source" => "stack-dismissed"}] =
             pull_requests(id)
  end

  test "a merged pull request settles its thread", %{dir: dir} do
    id = thread!("t-merged")
    {:ok, _} = link(id, 5, "manual")
    rules!(dir, [summary_rule("MERGED", Entities.now()), stack_rule(404)])
    start_supervised!({Sync, interval: nil})
    start_supervised!({Settlement, interval: nil})

    :ok = Sync.sweep()
    await_row(id, &match?([%{"snapshot" => %{"state" => "merged"}}], &1["pullRequests"]))
    :ok = Settlement.sweep()

    assert %{"settledOverride" => "settled", "settledAt" => settled_at, "createdAt" => settled_at} =
             thread(id)
  end

  # --- helpers ---------------------------------------------------------------------------

  defp thread!(id, fields \\ %{}) do
    {:ok, _} =
      Orchestration.dispatch(
        Map.merge(
          %{
            "type" => "thread.create",
            "threadId" => id,
            "projectId" => "p1",
            "title" => id,
            "modelSelection" => %{"instanceId" => "codex", "model" => "gpt-5.4"}
          },
          fields
        )
      )

    await_row(id, & &1)
    id
  end

  defp link(id, number, source, url \\ nil),
    do:
      Orchestration.dispatch(%{
        "type" => "thread.pull-request.link",
        "threadId" => id,
        "host" => "github.com",
        "repository" => "acme/widgets",
        "number" => number,
        "url" => url || "#{@url}#{number}",
        "source" => source
      })

  defp unlink(id, number),
    do:
      Orchestration.dispatch(%{
        "type" => "thread.pull-request.unlink",
        "threadId" => id,
        "host" => "github.com",
        "repository" => "acme/widgets",
        "number" => number
      })

  defp sync_link(id, number, snapshot, stack),
    do:
      Orchestration.dispatch(%{
        "type" => "thread.pull-request-link.sync",
        "threadId" => id,
        "host" => "github.com",
        "repository" => "acme/widgets",
        "number" => number,
        "snapshot" => snapshot,
        "stack" => stack
      })

  defp sync_branch(id, expected, found),
    do:
      Orchestration.dispatch(%{
        "type" => "thread.pull-request.sync",
        "threadId" => id,
        "projectId" => "p1",
        "expected" => expected,
        "branchPullRequest" => found
      })

  defp current(id), do: T3.Streams.Server.state(T3.Streams.ensure(id))
  defp thread(id), do: StreamState.get(current(id), "thread")[id]
  defp pull_requests(id), do: T3.Projection.PullRequests.of(thread(id))

  # Waits on the sidebar until the stream's row satisfies `fun`.
  defp await_row(id, fun) do
    case T3.Shell.row(node(), id) do
      {_kind, row} -> if fun.(row), do: row, else: await_next_row(id, fun)
      nil -> await_next_row(id, fun)
    end
  end

  defp await_next_row(id, fun) do
    receive do
      {:t3_shell, {:rows, _, rows}} ->
        case List.keyfind(rows, id, 0) do
          {^id, {_kind, row}} -> if fun.(row), do: row, else: await_next_row(id, fun)
          nil -> await_next_row(id, fun)
        end
    after
      2_000 -> flunk("#{id}'s row never changed as expected")
    end
  end

  defp rules!(dir, rules), do: File.write!(Path.join(dir, "rules.json"), JSON.encode!(rules))

  defp calls(dir, fragment) do
    case File.read(Path.join(dir, "gh.log")) do
      {:ok, log} ->
        log
        |> String.split("\n", trim: true)
        |> Enum.map(&JSON.decode!/1)
        |> Enum.filter(&String.contains?(Enum.join(&1["args"], " "), fragment))

      {:error, :enoent} ->
        []
    end
  end

  # Every alias answers alike, so the order a batch asks in does not matter.
  defp summary_rule(state, merged_at) do
    pr = %{
      "title" => "PR",
      "url" => "#{@url}5",
      "state" => state,
      "isDraft" => false,
      "headRefName" => "feature",
      "baseRefName" => "main",
      "updatedAt" => "2026-03-01T00:00:00Z",
      "mergedAt" => merged_at,
      "author" => %{"login" => "someone"}
    }

    %{
      "args" => ["api graphql"],
      "stdin" => ["PullRequestSummaries"],
      "stdout" => %{"data" => %{"s0" => %{"pullRequest" => pr}, "s1" => %{"pullRequest" => pr}}}
    }
  end

  defp stack_rule(404),
    do: %{"args" => ["stacks?pull_request="], "stderr" => "HTTP 404: Not Found", "exit" => 1}

  defp stack_rule do
    %{
      "args" => ["stacks?pull_request="],
      "stdout" => [
        %{
          "id" => 42,
          "number" => 1,
          "html_url" => "https://github.com/acme/widgets/stacks/1",
          "base" => "main",
          "pull_requests" => [
            %{"number" => 5, "head" => %{"ref" => "feature-5"}, "state" => "open"},
            %{"number" => 6, "head" => %{"ref" => "feature-6"}, "state" => "open"}
          ]
        }
      ]
    }
  end
end
