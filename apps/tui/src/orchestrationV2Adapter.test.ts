import { describe, expect, it } from "bun:test";

import {
  ProjectId,
  ProviderInstanceId,
  RunId,
  ThreadId,
  TurnItemId,
  type OrchestrationProjectShell,
  type OrchestrationV2ThreadProjection,
  type OrchestrationV2ThreadShell,
} from "@t3tools/contracts";
import * as DateTime from "effect/DateTime";

import { presentTuiShell, presentTuiThread } from "./orchestrationV2Adapter.ts";

const now = DateTime.makeUnsafe("2026-08-11T10:00:00.000Z");
const projectId = ProjectId.make("project-1");
const threadId = ThreadId.make("thread-1");
const providerInstanceId = ProviderInstanceId.make("codex");

const project: OrchestrationProjectShell = {
  id: projectId,
  title: "Project",
  workspaceRoot: "/workspace/project",
  repositoryIdentity: null,
  defaultModelSelection: null,
  scripts: [],
  createdAt: "2026-08-11T09:00:00.000Z",
  updatedAt: "2026-08-11T09:00:00.000Z",
};

function shell(overrides: Partial<OrchestrationV2ThreadShell> = {}): OrchestrationV2ThreadShell {
  return {
    id: threadId,
    projectId,
    title: "Thread",
    providerInstanceId,
    modelSelection: { instanceId: providerInstanceId, model: "gpt-5.6" },
    runtimeMode: "full-access",
    interactionMode: "default",
    branch: null,
    worktreePath: null,
    activeProviderThreadId: null,
    lineage: { rootThreadId: threadId, parentThreadId: null, relationshipToParent: null },
    forkedFrom: null,
    createdBy: "user",
    creationSource: "web",
    latestRunId: null,
    activeRunId: null,
    status: "idle",
    pendingRuntimeRequest: null,
    latestVisibleMessage: null,
    latestUserMessageAt: null,
    hasActionableProposedPlan: false,
    itemCount: 0,
    visibleItemCount: 0,
    createdAt: now,
    updatedAt: now,
    archivedAt: null,
    settledOverride: null,
    settledAt: null,
    lastVisitedAt: null,
    deletedAt: null,
    ...overrides,
  };
}

function projection(): OrchestrationV2ThreadProjection {
  const thread = shell();
  const reasoningItem = {
    id: TurnItemId.make("item-1"),
    threadId,
    runId: RunId.make("run-1"),
    nodeId: null,
    providerThreadId: null,
    providerTurnId: null,
    nativeItemRef: null,
    parentItemId: null,
    ordinal: 0,
    status: "completed",
    title: null,
    startedAt: now,
    completedAt: now,
    updatedAt: now,
    type: "reasoning",
    text: "Mapped the turn",
    streaming: false,
  } as const;
  return {
    thread: {
      id: thread.id,
      projectId: thread.projectId,
      title: thread.title,
      providerInstanceId: thread.providerInstanceId,
      modelSelection: thread.modelSelection,
      runtimeMode: thread.runtimeMode,
      interactionMode: thread.interactionMode,
      branch: thread.branch,
      worktreePath: thread.worktreePath,
      activeProviderThreadId: thread.activeProviderThreadId,
      lineage: thread.lineage,
      forkedFrom: thread.forkedFrom,
      createdBy: thread.createdBy,
      creationSource: thread.creationSource,
      createdAt: now,
      updatedAt: now,
      archivedAt: null,
      settledOverride: null,
      settledAt: null,
      lastVisitedAt: null,
      deletedAt: null,
    },
    runs: [],
    attempts: [],
    nodes: [],
    subagents: [],
    providerSessions: [],
    providerThreads: [],
    providerTurns: [],
    runtimeRequests: [],
    messages: [],
    plans: [],
    turnItems: [reasoningItem],
    checkpointScopes: [],
    checkpoints: [],
    contextHandoffs: [],
    contextTransfers: [],
    visibleTurnItems: [
      {
        position: 0,
        visibility: "local",
        sourceThreadId: threadId,
        sourceItemId: reasoningItem.id,
        item: reasoningItem,
      },
    ],
    updatedAt: now,
  };
}

describe("orchestration V2 TUI presentation", () => {
  it("preserves active and archived threads in the legacy shell view", () => {
    const activeRunId = RunId.make("run-active");
    const result = presentTuiShell({
      schemaVersion: 1,
      snapshotSequence: 42,
      projects: [project],
      threads: [
        shell({
          latestRunId: activeRunId,
          activeRunId,
          activityRunStatus: "running",
          status: "running",
        }),
      ],
      archivedThreads: [
        shell({
          id: ThreadId.make("thread-archived"),
          archivedAt: now,
        }),
      ],
    });

    expect(result.snapshotSequence).toBe(42);
    expect(result.threads.map((thread) => thread.id)).toEqual([
      threadId,
      ThreadId.make("thread-archived"),
    ]);
    expect(result.threads[0]?.latestTurn?.state).toBe("running");
    expect(result.threads[0]?.session?.status).toBe("running");
    expect(result.threads[1]?.archivedAt).toBe("2026-08-11T10:00:00.000Z");
  });

  it("maps visible V2 turn items into timeline activities", () => {
    const result = presentTuiThread(projection());

    expect(result.id).toBe(threadId);
    expect(result.activities).toHaveLength(1);
    expect(result.activities[0]).toMatchObject({
      kind: "task.completed",
      summary: "Thinking",
      sequence: 0,
      payload: {
        title: "Thinking",
        detail: "Mapped the turn",
        status: "completed",
      },
    });
  });
});
