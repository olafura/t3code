defmodule T3.Projection.ShellTest do
  use ExUnit.Case, async: true

  alias T3.Projection.Shell
  alias T3.StreamState

  @thread %{
    "id" => "thread-1",
    "projectId" => "project-1",
    "title" => "Thread",
    "createdBy" => "user",
    "creationSource" => "web",
    "providerInstanceId" => "codex",
    "modelSelection" => %{"instanceId" => "codex", "model" => "gpt-5"},
    "runtimeMode" => "full-access",
    "interactionMode" => "default",
    "branch" => :null,
    "worktreePath" => :null,
    "activeProviderThreadId" => :null,
    "lineage" => %{
      "parentThreadId" => :null,
      "relationshipToParent" => :null,
      "rootThreadId" => "thread-1"
    },
    "forkedFrom" => :null,
    "createdAt" => "2026-09-01T10:00:00.000Z",
    "updatedAt" => "2026-09-01T10:00:00.000Z",
    "archivedAt" => :null,
    "deletedAt" => :null
  }

  # Folds `{kind, entity}` pairs in order, one event each, one second apart.
  defp state(entities) do
    entities
    |> Enum.with_index(1)
    |> Enum.reduce(StreamState.new(), fn {{kind, entity}, seq}, state ->
      StreamState.apply_event(state, %{
        seq: seq,
        kind: kind,
        entity: entity["id"],
        patch: %{"s" => entity},
        at: 1_788_256_800_000 + seq * 1000
      })
    end)
  end

  defp run(id, ordinal, status, extra \\ %{}) do
    Map.merge(
      %{
        "id" => id,
        "threadId" => "thread-1",
        "ordinal" => ordinal,
        "status" => status,
        "rootNodeId" => "node-#{id}",
        "requestedAt" => "2026-09-01T10:0#{ordinal}:00.000Z",
        "startedAt" => :null,
        "completedAt" => :null
      },
      extra
    )
  end

  defp item(id, run_id, extra \\ %{}) do
    Map.merge(
      %{
        "id" => id,
        "threadId" => "thread-1",
        "runId" => run_id,
        "nodeId" => :null,
        "type" => "assistant_message",
        "status" => "completed",
        "ordinal" => 0,
        "updatedAt" => "2026-09-01T10:00:00.000Z"
      },
      extra
    )
  end

  test "a new thread is idle, with null defaults and legacy fields normalized" do
    legacy_selection = %{"provider" => "claude", "model" => "opus"}

    shell =
      Shell.thread_shell(state([{"thread", %{@thread | "modelSelection" => legacy_selection}}]))

    assert %{
             "status" => "idle",
             "latestRunId" => nil,
             "activeRunId" => nil,
             "activityRunStatus" => nil,
             "pendingRuntimeRequest" => nil,
             "lastError" => nil,
             "lastErrorClass" => nil,
             "lastVisitedAt" => nil,
             "settledOverride" => nil,
             "pullRequests" => [],
             "pendingBackgroundTasks" => [],
             "providerInstanceHistory" => [],
             "itemCount" => 0,
             "modelSelection" => %{"instanceId" => "claude", "model" => "opus"},
             "lineage" => %{"parentThreadId" => nil},
             "updatedAt" => "2026-09-01T10:00:01.000Z"
           } = shell

    # Optional fields the thread never had are omitted, not null.
    refute Map.has_key?(shell, "historyOrigin")
    refute Map.has_key?(shell, "linkedPullRequest")
  end

  test "the activity run is the newest active one, and waiting counts only as activity" do
    shell =
      Shell.thread_shell(
        state([
          {"thread", @thread},
          {"run", run("run-1", 1, "running", %{"startedAt" => "2026-09-01T10:01:30.000Z"})},
          {"run", run("run-2", 2, "preparing")},
          {"run", run("run-3", 3, "waiting")},
          {"run", run("run-4", 4, "queued")}
        ])
      )

    assert %{
             "status" => "queued",
             "latestRunId" => "run-4",
             "activeRunId" => "run-2",
             "activityRunStatus" => "waiting",
             "activityRunStartedAt" => "2026-09-01T10:03:00.000Z"
           } = shell

    preparing =
      Shell.thread_shell(state([{"thread", @thread}, {"run", run("run-2", 2, "preparing")}]))

    # A preparing run has not started; its request time stands in.
    assert preparing["activityRunStartedAt"] == "2026-09-01T10:02:00.000Z"
  end

  test "the pending runtime request is the most recently created pending one" do
    request = fn id, status, created_at ->
      {"runtime-request",
       %{"id" => id, "kind" => "approval", "status" => status, "createdAt" => created_at}}
    end

    shell =
      Shell.thread_shell(
        state([
          {"thread", @thread},
          request.("old", "pending", "2026-09-01T10:00:00Z"),
          request.("answered", "resolved", "2026-09-01T12:00:00.000Z"),
          request.("new", "pending", "2026-09-01T11:00:00.000+01:00"),
          request.("newest", "pending", "2026-09-01T10:30:00.000Z"),
          request.("tie", "pending", "2026-09-01T10:30:00.000Z")
        ])
      )

    assert shell["pendingRuntimeRequest"] == %{
             "id" => "newest",
             "kind" => "approval",
             "createdAt" => "2026-09-01T10:30:00.000Z"
           }
  end

  test "only an active proposed plan is actionable" do
    plan = fn status ->
      {"plan", %{"id" => "plan-#{status}", "kind" => "proposed_plan", "status" => status}}
    end

    refute Shell.thread_shell(state([{"thread", @thread}, plan.("superseded")]))[
             "hasActionableProposedPlan"
           ]

    assert Shell.thread_shell(state([{"thread", @thread}, plan.("active")]))[
             "hasActionableProposedPlan"
           ]
  end

  describe "errors" do
    defp error_item(id, updated_at, failure, extra \\ %{}) do
      item(
        id,
        "run-1",
        Map.merge(
          %{
            "type" => "error",
            "status" => "failed",
            "nodeId" => "node-run-1",
            "updatedAt" => updated_at,
            "failure" => failure
          },
          extra
        )
      )
    end

    defp failure(class, message, extra \\ %{}),
      do:
        Map.merge(
          %{"class" => class, "message" => message, "code" => :null, "retryable" => :null},
          extra
        )

    test "the latest root error of a failed run is the thread's error" do
      limit = failure("usage_limit", "Limit reached", %{"resetAt" => "2026-09-02T00:00:00.000Z"})

      entities = [
        {"thread", @thread},
        {"run", run("run-1", 1, "failed")},
        {"turn-item", error_item("late", "2026-09-01T10:05:00.000Z", limit)},
        {"turn-item",
         error_item("early", "2026-09-01T10:04:00.000Z", failure("provider_error", "boom"))},
        # A child node's failure does not own the thread's state.
        {"turn-item",
         error_item("child", "2026-09-01T10:09:00.000Z", failure("provider_error", "child"), %{
           "nodeId" => "node-child"
         })}
      ]

      assert %{
               "lastError" => "Limit reached",
               "lastErrorClass" => "usage_limit",
               "usageLimitResetAt" => "2026-09-02T00:00:00.000Z"
             } = Shell.thread_shell(state(entities))

      # A different session error on the thread's provider supersedes the classification.
      session = %{
        "id" => "session-1",
        "providerInstanceId" => "codex",
        "updatedAt" => "2026-09-01T10:06:00.000Z",
        "lastError" => "Session crashed"
      }

      assert %{
               "lastError" => "Session crashed",
               "lastErrorClass" => nil,
               "usageLimitResetAt" => nil
             } =
               Shell.thread_shell(state(entities ++ [{"provider-session", session}]))

      # Once the run is retried and succeeds, the old failure no longer shows.
      recovered = entities ++ [{"run", run("run-2", 2, "completed")}]
      assert %{"lastError" => nil, "status" => "completed"} = Shell.thread_shell(state(recovered))
    end
  end

  test "provider instance history lists root provider threads' instances, oldest first" do
    provider_thread = fn id, instance, created_at, extra ->
      {"provider-thread",
       Map.merge(
         %{
           "id" => id,
           "appThreadId" => "thread-1",
           "ownerNodeId" => :null,
           "providerInstanceId" => instance,
           "createdAt" => created_at
         },
         extra
       )}
    end

    shell =
      Shell.thread_shell(
        state([
          {"thread", @thread},
          provider_thread.("pt-c", "codex", "2026-09-01T12:00:00.000Z", %{}),
          provider_thread.("pt-a", "claude", "2026-09-01T11:00:00.000Z", %{}),
          provider_thread.("pt-b", "codex", "2026-09-01T11:30:00.000Z", %{}),
          provider_thread.("pt-sub", "grok", "2026-09-01T10:00:00.000Z", %{
            "ownerNodeId" => "node-1"
          }),
          provider_thread.("pt-other", "cursor", "2026-09-01T10:00:00.000Z", %{
            "appThreadId" => "thread-2"
          })
        ])
      )

    assert shell["providerInstanceHistory"] == ["claude", "codex"]
  end

  test "a legacy linked pull request becomes a link" do
    linked = %{
      "projectId" => "project-1",
      "repository" => "Acme/Widgets",
      "number" => 12,
      "url" => "https://github.com/Acme/Widgets/pull/12"
    }

    shell = Shell.thread_shell(state([{"thread", Map.put(@thread, "linkedPullRequest", linked)}]))

    assert shell["linkedPullRequest"] == linked

    assert shell["pullRequests"] == [
             %{
               "host" => "github.com",
               "repository" => "acme/widgets",
               "number" => 12,
               "url" => "https://github.com/Acme/Widgets/pull/12",
               "source" => "manual",
               "linkedAt" => "1970-01-01T00:00:00.000Z",
               "snapshot" => nil,
               "stack" => nil
             }
           ]
  end

  describe "visible items" do
    test "rolled-back runs and superseded interrupts are not counted" do
      shell =
        Shell.thread_shell(
          state([
            {"thread", @thread},
            {"run", run("run-1", 1, "completed")},
            {"run", run("run-2", 2, "rolled_back")},
            {"run-attempt",
             %{"id" => "a-1", "runId" => "run-1", "rootNodeId" => "n-1", "status" => "superseded"}},
            {"turn-item", item("kept", "run-1")},
            {"turn-item",
             item("interrupt", "run-1", %{"type" => "run_interrupt_result", "nodeId" => "n-1"})},
            {"turn-item", item("undone", "run-2")}
          ])
        )

      assert %{"itemCount" => 1, "visibleItemCount" => 1} = shell
    end

    test "a fork of a run counts the source's history through that run and a marker" do
      source =
        state([
          {"thread", %{@thread | "id" => "source"}},
          {"run", run("run-1", 1, "completed")},
          {"run", run("run-2", 2, "completed")},
          {"turn-item", item("s1", "run-1", %{"threadId" => "source"})},
          {"turn-item", item("s2", "run-2", %{"threadId" => "source"})},
          {"turn-item", item("s0", :null, %{"threadId" => "source"})}
        ])

      fork_of = fn parent, run_id, id ->
        %{
          @thread
          | "id" => id,
            "forkedFrom" => %{"type" => "run", "threadId" => parent, "runId" => run_id}
        }
      end

      fork =
        state([
          {"thread", fork_of.("source", "run-1", "fork")},
          {"run", run("run-f", 1, "completed", %{"threadId" => "fork"})},
          {"turn-item", item("f1", "run-f", %{"threadId" => "fork"})}
        ])

      # s1 through run-1, the marker, f1. s0 has no run and the source is native history.
      assert %{"itemCount" => 1, "visibleItemCount" => 3} = Shell.thread_shell(fork, source)
      assert Shell.thread_shell(fork)["visibleItemCount"] == 1

      # A fork of the fork inherits the fork's history, its marker included.
      nested = state([{"thread", fork_of.("fork", "run-f", "nested")}])
      states = %{"source" => source, "fork" => fork}
      assert Shell.thread_shell(nested, &states[&1])["visibleItemCount"] == 3 + 1

      # A source run that no longer exists leaves only the marker.
      gone = state([{"thread", fork_of.("source", "run-9", "gone")}])
      assert Shell.thread_shell(gone, source)["visibleItemCount"] == 1
    end
  end
end
