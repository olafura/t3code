import type { EnvironmentThreadShell } from "@t3tools/client-runtime/state/models";
import { scopeThreadRef, scopedThreadKey } from "@t3tools/client-runtime/environment";
import type { ShellDesktopNotification } from "@t3tools/contracts/shell";

import { randomUUID } from "../lib/utils";

type NotificationThread = Pick<
  EnvironmentThreadShell,
  | "id"
  | "environmentId"
  | "title"
  | "archivedAt"
  | "latestTurn"
  | "hasPendingApprovals"
  | "hasPendingUserInput"
  | "runtimeMode"
>;

/** Observes transitions, not historical completions on initial load or new environments. */
export function createDesktopNotificationTracker() {
  const instanceId = randomUUID();
  let previous = new Map<string, NotificationThread>();
  let sequence = 0;
  return (threads: ReadonlyArray<NotificationThread>): ShellDesktopNotification[] => {
    const next = new Map<string, NotificationThread>();
    const events: ShellDesktopNotification[] = [];
    for (const thread of threads) {
      const key = scopedThreadKey(scopeThreadRef(thread.environmentId, thread.id));
      next.set(key, thread);
      const before = previous.get(key);
      if (!before || thread.archivedAt !== null) continue;
      const emit = (kind: ShellDesktopNotification["kind"]) => {
        events.push({
          id: `${instanceId}:${key}:${++sequence}`,
          threadKey: key,
          kind,
          threadTitle: thread.title,
          runtimeMode: thread.runtimeMode,
        });
      };
      const turn = thread.latestTurn;
      if (
        turn?.state === "completed" &&
        turn.completedAt !== null &&
        (before.latestTurn?.turnId !== turn.turnId || before.latestTurn?.state !== "completed")
      ) {
        emit("completed");
      }
      if (thread.hasPendingApprovals && !before.hasPendingApprovals) {
        emit("approval");
      }
      if (thread.hasPendingUserInput && !before.hasPendingUserInput) emit("input");
      if (
        turn &&
        (before.latestTurn?.turnId !== turn.turnId || before.latestTurn?.state !== turn.state)
      ) {
        if (turn.state === "running") emit("started");
        if (turn.state === "error") emit("error");
      }
    }
    previous = next;
    return events;
  };
}
