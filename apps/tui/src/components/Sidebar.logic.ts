import {
  DEFAULT_SIDEBAR_THREAD_PREVIEW_COUNT,
  type OrchestrationThreadShell,
} from "@t3tools/contracts";

import type { OrchestrationShellSnapshot } from "../connection.ts";
import { herdrWorkspaceCwd } from "../herdr/host.ts";
import type { HerdrAgentInfo, HerdrAgentStatus, HerdrSessionSnapshot } from "../herdr/protocol.ts";
import { resolveProjectStatus, type ThreadStatus } from "../theme.ts";

// Pure logic backing the Sidebar (mirrors apps/web/src/components/Sidebar.logic.ts):
// the row model, selection identity, the preview/"show more" windowing, and the
// flat row builder. No rendering, so it's trivially testable.

export type Selection =
  | { readonly kind: "project"; readonly id: string }
  | { readonly kind: "thread"; readonly id: string }
  | { readonly kind: "space"; readonly id: string }
  | { readonly kind: "agent"; readonly id: string }
  | { readonly kind: "more"; readonly id: string };

export type Row =
  | {
      readonly kind: "project";
      readonly id: string;
      readonly title: string;
      readonly count: number;
      readonly status: ThreadStatus | null;
      readonly expanded: boolean;
    }
  | { readonly kind: "thread"; readonly id: string; readonly thread: OrchestrationThreadShell }
  | {
      readonly kind: "space";
      readonly id: string;
      readonly title: string;
      readonly count: number;
      readonly status: ThreadStatus | null;
      readonly expanded: boolean;
    }
  | {
      readonly kind: "agent";
      readonly id: string;
      readonly title: string;
      readonly agent: HerdrAgentInfo;
      readonly status: ThreadStatus;
    }
  | { readonly kind: "more"; readonly id: string; readonly hiddenCount: number };

export const herdrSpaceExpansionKey = (workspaceId: string): string => `herdr:${workspaceId}`;

const HERDR_STATUS: Readonly<Record<HerdrAgentStatus, ThreadStatus>> = {
  blocked: {
    key: "herdr-blocked",
    glyph: "◆",
    color: "yellow",
    bold: true,
    label: "Blocked",
    rank: 0,
  },
  working: {
    key: "herdr-working",
    glyph: "●",
    color: "green",
    bold: true,
    label: "Working",
    rank: 1,
  },
  done: {
    key: "herdr-done",
    glyph: "✓",
    color: "green",
    bold: false,
    label: "Done",
    rank: 2,
  },
  idle: {
    key: "herdr-idle",
    glyph: "○",
    color: "gray",
    bold: false,
    label: "Idle",
    rank: 3,
  },
  unknown: {
    key: "herdr-unknown",
    glyph: "◌",
    color: "gray",
    bold: false,
    label: "Unknown",
    rank: 4,
  },
};

export function resolveHerdrAgentStatus(status: HerdrAgentStatus): ThreadStatus {
  return HERDR_STATUS[status];
}

function canonicalPath(value: string | null | undefined): string | null {
  if (!value) return null;
  return value.replaceAll("\\", "/").replace(/\/+$/, "");
}

export function findProjectForHerdrSpace(
  shell: OrchestrationShellSnapshot | null,
  herdr: HerdrSessionSnapshot | null,
  workspaceId: string,
): OrchestrationShellSnapshot["projects"][number] | null {
  if (!shell || !herdr) return null;
  const cwd = canonicalPath(herdrWorkspaceCwd(herdr, workspaceId));
  if (!cwd) return null;
  return shell.projects.find((project) => canonicalPath(project.workspaceRoot) === cwd) ?? null;
}

function agentTitle(agent: HerdrAgentInfo): string {
  return (
    agent.name ??
    agent.display_agent ??
    agent.title ??
    agent.terminal_title_stripped ??
    agent.agent ??
    agent.pane_id
  );
}

export function selectionEquals(selection: Selection | null, row: Row): boolean {
  return selection !== null && selection.kind === row.kind && selection.id === row.id;
}

/**
 * Only the top {@link DEFAULT_SIDEBAR_THREAD_PREVIEW_COUNT} threads of a project
 * render until its list is loaded in full — mirroring the web sidebar. The
 * currently selected thread is always kept visible.
 */
export function visibleThreadsForProject(
  threads: ReadonlyArray<OrchestrationThreadShell>,
  loadedInFull: boolean,
  selectedThreadId: string | null,
): { readonly visible: OrchestrationThreadShell[]; readonly hidden: number } {
  const limit = DEFAULT_SIDEBAR_THREAD_PREVIEW_COUNT;
  if (loadedInFull || threads.length <= limit) {
    return { visible: [...threads], hidden: 0 };
  }
  const preview = threads.slice(0, limit);
  const selectedHidden =
    selectedThreadId !== null &&
    !preview.some((thread) => thread.id === selectedThreadId) &&
    threads.some((thread) => thread.id === selectedThreadId);
  if (!selectedHidden) {
    return { visible: preview, hidden: threads.length - limit };
  }
  const selected = threads.find((thread) => thread.id === selectedThreadId);
  return {
    visible: selected ? [...preview, selected] : preview,
    hidden: threads.length - limit - (selected ? 1 : 0),
  };
}

/**
 * Pure: build the visible rows from the snapshot + UI state. When `filter` is
 * non-empty, projects auto-expand and only matching threads (or all threads of a
 * project whose own title matches) are shown, with no "show more" row.
 */
export function buildRows(
  shell: OrchestrationShellSnapshot | null,
  expanded: ReadonlySet<string>,
  loadedInFull: ReadonlySet<string>,
  selectedThreadId: string | null,
  filter = "",
  herdr: HerdrSessionSnapshot | null = null,
): Row[] {
  if (!shell) return [];
  const needle = filter.trim().toLowerCase();
  const projectTitles = new Map<string, string>(
    shell.projects.map((project) => [project.id, project.title]),
  );
  const projectsById = new Map(shell.projects.map((project) => [project.id as string, project]));
  const byProject = new Map<string, OrchestrationThreadShell[]>();
  for (const thread of shell.threads) {
    const list = byProject.get(thread.projectId);
    if (list) list.push(thread);
    else byProject.set(thread.projectId, [thread]);
  }

  // Sort key: a project's most-recently-updated thread, falling back to the
  // project's own updatedAt/createdAt — so projects order by latest activity
  // (most recent first), matching how the web sidebar sorts them. ISO timestamps
  // compare chronologically as strings; "" (no activity) sorts last.
  const sortKey = (id: string): string => {
    const threads = byProject.get(id);
    if (threads && threads.length > 0) {
      let key = "";
      for (const thread of threads) if (thread.updatedAt > key) key = thread.updatedAt;
      return key;
    }
    const project = projectsById.get(id);
    return project?.updatedAt ?? project?.createdAt ?? "";
  };

  // All catalogue projects (so the list matches the "N project(s)" count and an
  // empty project is still visible/selectable), then any orphaned project ids,
  // sorted by latest activity with title/id as the tie-breaker.
  const orderedIds: string[] = [
    ...shell.projects.map((project) => project.id as string),
    ...[...byProject.keys()].filter((id) => !projectTitles.has(id)),
  ].toSorted((a, b) => {
    const byTime = sortKey(b).localeCompare(sortKey(a));
    if (byTime !== 0) return byTime;
    return (projectTitles.get(a) ?? a).localeCompare(projectTitles.get(b) ?? b) || a.localeCompare(b);
  });

  const rows: Row[] = [];
  const matchedThreadIds = new Set<string>();
  const matchedProjectIds = new Set<string>();

  if (herdr) {
    for (const workspace of herdr.workspaces) {
      const cwd = canonicalPath(herdrWorkspaceCwd(herdr, workspace.workspace_id));
      const agents = herdr.agents.filter((agent) => agent.workspace_id === workspace.workspace_id);
      const directProjects = shell.projects.filter(
        (project) => canonicalPath(project.workspaceRoot) === cwd,
      );
      const directProjectIds = new Set(directProjects.map((project) => project.id as string));
      const threads = shell.threads.filter((thread) => {
        const project = projectsById.get(thread.projectId as string);
        const threadCwd = canonicalPath(thread.worktreePath ?? project?.workspaceRoot);
        return threadCwd === cwd || directProjectIds.has(thread.projectId as string);
      });
      for (const project of directProjects) matchedProjectIds.add(project.id as string);
      for (const thread of threads) {
        matchedThreadIds.add(thread.id as string);
        matchedProjectIds.add(thread.projectId as string);
      }

      const spaceMatches = workspace.label.toLowerCase().includes(needle);
      const shownThreads =
        needle.length === 0 || spaceMatches
          ? threads
          : threads.filter((thread) => thread.title.toLowerCase().includes(needle));
      const shownAgents =
        needle.length === 0 || spaceMatches
          ? agents
          : agents.filter((agent) => agentTitle(agent).toLowerCase().includes(needle));
      if (
        needle.length > 0 &&
        !spaceMatches &&
        shownThreads.length === 0 &&
        shownAgents.length === 0
      ) {
        continue;
      }
      const isExpanded =
        needle.length > 0 || expanded.has(herdrSpaceExpansionKey(workspace.workspace_id));
      rows.push({
        kind: "space",
        id: workspace.workspace_id,
        title: workspace.label,
        count: shownThreads.length + shownAgents.length,
        status:
          workspace.agent_status === "unknown"
            ? null
            : resolveHerdrAgentStatus(workspace.agent_status),
        expanded: isExpanded,
      });
      if (!isExpanded) continue;
      for (const thread of shownThreads) {
        rows.push({ kind: "thread", id: thread.id, thread });
      }
      for (const agent of shownAgents) {
        rows.push({
          kind: "agent",
          id: agent.pane_id,
          title: agentTitle(agent),
          agent,
          status: resolveHerdrAgentStatus(agent.agent_status),
        });
      }
    }
  }

  for (const id of orderedIds) {
    const threads = (byProject.get(id) ?? []).filter(
      (thread) => !matchedThreadIds.has(thread.id as string),
    );
    const title = projectTitles.get(id) ?? id;
    if (matchedProjectIds.has(id) && threads.length === 0) continue;

    if (needle.length > 0) {
      const projectMatches = title.toLowerCase().includes(needle);
      const shown = projectMatches
        ? threads
        : threads.filter((thread) => thread.title.toLowerCase().includes(needle));
      if (shown.length === 0 && !projectMatches) continue;
      rows.push({
        kind: "project",
        id,
        title,
        count: shown.length,
        status: resolveProjectStatus(shown),
        expanded: true,
      });
      for (const thread of shown) rows.push({ kind: "thread", id: thread.id, thread });
      continue;
    }

    const isExpanded = expanded.has(id);
    rows.push({
      kind: "project",
      id,
      title,
      count: threads.length,
      status: resolveProjectStatus(threads),
      expanded: isExpanded,
    });
    if (isExpanded) {
      const { visible, hidden } = visibleThreadsForProject(
        threads,
        loadedInFull.has(id),
        selectedThreadId,
      );
      for (const thread of visible) {
        rows.push({ kind: "thread", id: thread.id, thread });
      }
      if (hidden > 0) {
        rows.push({ kind: "more", id, hiddenCount: hidden });
      }
    }
  }
  return rows;
}
