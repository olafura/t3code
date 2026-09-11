import type { TuiShellSnapshot } from "./orchestrationV2Adapter.ts";

/** Direct subthreads and the way back, without mixing forks into the agent list. */
export function getSubthreadNavigation(shell: TuiShellSnapshot | null, threadId: string | null) {
  const current = shell?.threads.find((thread) => thread.id === threadId);
  const parentId =
    current?.lineage.relationshipToParent === "subagent" ? current.lineage.parentThreadId : null;
  const parent =
    parentId === null
      ? null
      : (shell?.threads.find((thread) => thread.id === parentId && thread.archivedAt === null) ??
        null);
  const children =
    threadId === null
      ? []
      : (shell?.threads ?? []).filter(
          (thread) =>
            thread.archivedAt === null &&
            thread.lineage.relationshipToParent === "subagent" &&
            thread.lineage.parentThreadId === threadId,
        );
  return { parent, children };
}
