import { EnvironmentId, ThreadId, TurnId } from "@t3tools/contracts";
import { describe, expect, it } from "vite-plus/test";

import { createDesktopNotificationTracker } from "./shellDesktopNotifications";

const thread = {
  id: ThreadId.make("thread"),
  environmentId: EnvironmentId.make("environment"),
  title: "Review the sidebar",
  archivedAt: null,
  runtimeMode: "approval-required" as const,
  hasPendingApprovals: false,
  hasPendingUserInput: false,
  latestTurn: {
    turnId: TurnId.make("turn"),
    state: "running" as const,
    requestedAt: "2026-09-08T12:00:00.000Z",
    startedAt: "2026-09-08T12:00:01.000Z",
    completedAt: null,
    assistantMessageId: null,
  },
};
const completed = {
  ...thread,
  latestTurn: {
    ...thread.latestTurn,
    state: "completed" as const,
    completedAt: "2026-09-08T12:01:00.000Z",
  },
};

describe("desktop turn notification transitions", () => {
  it("does not reuse event IDs after the primary page reloads", () => {
    const beforeReload = createDesktopNotificationTracker();
    beforeReload([thread]);
    const first = beforeReload([completed]);
    const afterReload = createDesktopNotificationTracker();
    const nextTurn = { ...thread.latestTurn, turnId: TurnId.make("next") };
    afterReload([{ ...thread, latestTurn: nextTurn }]);
    const next = afterReload([
      { ...completed, latestTurn: { ...completed.latestTurn, turnId: nextTurn.turnId } },
    ]);
    expect(first).toHaveLength(1);
    expect(next).toHaveLength(1);
    expect(next[0]?.id).not.toBe(first[0]?.id);
  });

  it("does not notify about historical completions or pending approvals at startup", () => {
    const observe = createDesktopNotificationTracker();
    expect(observe([{ ...completed, hasPendingApprovals: true }])).toEqual([]);
    expect(observe([{ ...completed, title: "Renamed", hasPendingApprovals: true }])).toEqual([]);
  });

  it("emits one completed notification and ignores later metadata changes", () => {
    const observe = createDesktopNotificationTracker();
    observe([thread]);
    expect(observe([completed])).toMatchObject([{ kind: "completed", threadTitle: thread.title }]);
    expect(observe([{ ...completed, title: "Renamed" }])).toEqual([]);
  });

  it("notifies for a new completed turn even when its running update was coalesced", () => {
    const observe = createDesktopNotificationTracker();
    observe([completed]);
    expect(
      observe([
        { ...completed, latestTurn: { ...completed.latestTurn, turnId: TurnId.make("next") } },
      ]),
    ).toHaveLength(1);
  });

  it("notifies once for each approval wait, including a later wait in the same turn", () => {
    const observe = createDesktopNotificationTracker();
    observe([thread]);
    const waiting = { ...thread, hasPendingApprovals: true };
    const first = observe([waiting]);
    expect(first).toMatchObject([{ kind: "approval" }]);
    expect(observe([waiting])).toEqual([]);
    expect(observe([thread])).toEqual([]);
    expect(observe([waiting])[0]?.id).not.toBe(first[0]?.id);
  });

  it("exposes error, input and unsupervised approval transitions for QML policy, but skips archives", () => {
    const observe = createDesktopNotificationTracker();
    observe([thread]);
    expect(
      observe([{ ...completed, latestTurn: { ...completed.latestTurn, state: "error" } }]),
    ).toMatchObject([{ kind: "error" }]);
    expect(observe([{ ...completed, archivedAt: "2026-09-08T12:02:00.000Z" }])).toEqual([]);
    expect(
      observe([
        {
          ...thread,
          runtimeMode: "full-access",
          hasPendingApprovals: true,
          hasPendingUserInput: true,
        },
      ]),
    ).toMatchObject([
      { kind: "approval", runtimeMode: "full-access" },
      { kind: "input" },
      { kind: "started" },
    ]);
  });

  it("keeps environments independent and baselines threads that appear after reconnect", () => {
    const observe = createDesktopNotificationTracker();
    const remote = { ...thread, environmentId: EnvironmentId.make("remote") };
    observe([thread, remote]);
    expect(observe([thread, { ...completed, environmentId: remote.environmentId }])).toMatchObject([
      { threadKey: "remote:thread", kind: "completed" },
    ]);
    observe([]);
    expect(observe([completed])).toEqual([]);
  });
});
