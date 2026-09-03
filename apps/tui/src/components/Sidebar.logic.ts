import type { OrchestrationThreadShell } from "@t3tools/contracts";
import { effectiveSnoozed } from "@t3tools/client-runtime/state/thread-settled";

import type { OrchestrationShellSnapshot } from "../connection.ts";
import { herdrWorkspaceCwd } from "../herdr/host.ts";
import type { HerdrAgentStatus, HerdrSessionSnapshot } from "../herdr/protocol.ts";
import type { ThreadStatus } from "../theme.ts";

export const SIDEBAR_SNOOZED_SECTION_ID = "sidebar-v2:snoozed";
export const SIDEBAR_SETTLED_SECTION_ID = "sidebar-v2:settled";
export const SIDEBAR_SETTLED_INITIAL_COUNT = 10;

export type SidebarSection = "active" | "snoozed" | "settled";

export type Selection =
  | { readonly kind: "project"; readonly id: string }
  | { readonly kind: "thread"; readonly id: string }
  | { readonly kind: "space"; readonly id: string }
  | { readonly kind: "agent"; readonly id: string }
  | { readonly kind: "section"; readonly id: string }
  | { readonly kind: "more"; readonly id: string };

export type Row =
  | {
      readonly kind: "thread";
      readonly id: string;
      readonly thread: OrchestrationThreadShell;
      readonly section: SidebarSection;
      readonly projectTitle: string;
      readonly timestamp: string;
    }
  | {
      readonly kind: "section";
      readonly id: string;
      readonly section: Exclude<SidebarSection, "active">;
      readonly title: string;
      readonly count: number;
      readonly expanded: boolean;
    }
  | {
      readonly kind: "more";
      readonly id: string;
      readonly section: "settled";
      readonly hiddenCount: number;
    };

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

export function selectionEquals(selection: Selection | null, row: Row): boolean {
  return selection !== null && selection.kind === row.kind && selection.id === row.id;
}

function timestampMs(value: string | null | undefined): number {
  if (!value) return 0;
  const parsed = Date.parse(value);
  return Number.isNaN(parsed) ? 0 : parsed;
}

function activeOrder(left: OrchestrationThreadShell, right: OrchestrationThreadShell): number {
  return (
    timestampMs(right.createdAt) - timestampMs(left.createdAt) || left.id.localeCompare(right.id)
  );
}

export function settledTimestamp(thread: OrchestrationThreadShell): string {
  if (timestampMs(thread.settledAt) > 0) return thread.settledAt!;
  const candidates = [
    thread.latestUserMessageAt,
    thread.latestTurn?.requestedAt,
    thread.latestTurn?.startedAt,
    thread.latestTurn?.completedAt,
    thread.updatedAt,
  ];
  let latest = thread.updatedAt;
  for (const candidate of candidates) {
    if (timestampMs(candidate) > timestampMs(latest)) latest = candidate ?? latest;
  }
  return latest;
}

function selectedThread(
  threads: readonly OrchestrationThreadShell[],
  selectedThreadId: string | null,
): OrchestrationThreadShell | null {
  if (selectedThreadId === null) return null;
  return threads.find((thread) => thread.id === selectedThreadId) ?? null;
}

function keepSelectedVisible(
  visible: readonly OrchestrationThreadShell[],
  all: readonly OrchestrationThreadShell[],
  selectedThreadId: string | null,
): OrchestrationThreadShell[] {
  const selected = selectedThread(all, selectedThreadId);
  if (!selected || visible.some((thread) => thread.id === selected.id)) return [...visible];
  return [...visible, selected];
}

/**
 * Flat Sidebar V2 model shared by the standalone pane and Herdr's native
 * sidebar. Projects filter the list; they no longer own nested thread rows.
 *
 * The two sets retain the store's existing persistence shape:
 * - `expanded` contains the snoozed/settled section ids.
 * - `loadedInFull` contains the settled section id after "show more".
 */
export function buildRows(
  shell: OrchestrationShellSnapshot | null,
  expanded: ReadonlySet<string>,
  loadedInFull: ReadonlySet<string>,
  selectedThreadId: string | null,
  filter = "",
  _herdr: HerdrSessionSnapshot | null = null,
  _herdrContext: { readonly workspaceId: string; readonly cwd: string } | null = null,
  projectScopeId: string | null = null,
  now = new Date().toISOString(),
): Row[] {
  if (!shell) return [];

  const projectTitleById = new Map(
    shell.projects.map((project) => [project.id as string, project.title] as const),
  );
  const needle = filter.trim().toLowerCase();
  const visibleThreads = shell.threads.filter((thread) => {
    if (thread.archivedAt != null) return false;
    if (projectScopeId !== null && thread.projectId !== projectScopeId) return false;
    if (needle.length === 0) return true;
    const projectTitle = projectTitleById.get(thread.projectId as string) ?? thread.projectId;
    return (
      thread.title.toLowerCase().includes(needle) || projectTitle.toLowerCase().includes(needle)
    );
  });

  const active: OrchestrationThreadShell[] = [];
  const snoozed: OrchestrationThreadShell[] = [];
  const settled: OrchestrationThreadShell[] = [];
  for (const thread of visibleThreads) {
    // Snooze is the stronger lifecycle statement and therefore wins over a
    // settled thread, matching the web UI. The server projects settlement,
    // including auto-settle, into settledOverride.
    if (
      effectiveSnoozed(
        {
          ...thread,
          snoozedAt: thread.snoozedAt ?? null,
          snoozedUntil: thread.snoozedUntil ?? null,
        },
        { now },
      )
    ) {
      snoozed.push(thread);
    } else if (thread.settledOverride === "settled") {
      settled.push(thread);
    } else {
      active.push(thread);
    }
  }

  active.sort(activeOrder);
  snoozed.sort(
    (left, right) =>
      timestampMs(left.snoozedUntil) - timestampMs(right.snoozedUntil) ||
      left.id.localeCompare(right.id),
  );
  settled.sort(
    (left, right) =>
      timestampMs(settledTimestamp(right)) - timestampMs(settledTimestamp(left)) ||
      left.id.localeCompare(right.id),
  );

  const rowFor = (thread: OrchestrationThreadShell, section: SidebarSection): Row => ({
    kind: "thread",
    id: thread.id,
    thread,
    section,
    projectTitle: projectTitleById.get(thread.projectId as string) ?? thread.projectId,
    timestamp: section === "settled" ? settledTimestamp(thread) : thread.updatedAt,
  });

  const rows: Row[] = active.map((thread) => rowFor(thread, "active"));
  const searchExpanded = needle.length > 0;
  if (snoozed.length > 0) {
    const sectionExpanded = searchExpanded || expanded.has(SIDEBAR_SNOOZED_SECTION_ID);
    rows.push({
      kind: "section",
      id: SIDEBAR_SNOOZED_SECTION_ID,
      section: "snoozed",
      title: "Snoozed",
      count: snoozed.length,
      expanded: sectionExpanded,
    });
    const shown = sectionExpanded ? snoozed : keepSelectedVisible([], snoozed, selectedThreadId);
    rows.push(...shown.map((thread) => rowFor(thread, "snoozed")));
  }

  if (settled.length > 0) {
    const sectionExpanded = searchExpanded || expanded.has(SIDEBAR_SETTLED_SECTION_ID);
    rows.push({
      kind: "section",
      id: SIDEBAR_SETTLED_SECTION_ID,
      section: "settled",
      title: "Settled",
      count: settled.length,
      expanded: sectionExpanded,
    });
    const preview = loadedInFull.has(SIDEBAR_SETTLED_SECTION_ID)
      ? settled
      : settled.slice(0, SIDEBAR_SETTLED_INITIAL_COUNT);
    const shown = sectionExpanded
      ? keepSelectedVisible(preview, settled, selectedThreadId)
      : keepSelectedVisible([], settled, selectedThreadId);
    rows.push(...shown.map((thread) => rowFor(thread, "settled")));
    const hidden = settled.length - shown.length;
    if (sectionExpanded && hidden > 0) {
      rows.push({
        kind: "more",
        id: SIDEBAR_SETTLED_SECTION_ID,
        section: "settled",
        hiddenCount: hidden,
      });
    }
  }
  return rows;
}

/** Rendered height of a row: active thread cards take two terminal lines. */
export function rowHeight(row: Row): number {
  return row.kind === "thread" && row.section === "active" ? 2 : 1;
}
