import * as NodeBuffer from "node:buffer";

import type { Row, Selection } from "../components/Sidebar.logic.ts";
import { resolveThreadStatus, type ThreadStatus } from "../theme.ts";
import type { HerdrAgentStatus, HerdrAgentViewItem } from "./protocol.ts";

const ACTION_PREFIX = "\u001bP+t3-sidebar;";
const ACTION_SUFFIX = "\u001b\\";
const MAX_VIEW_ITEMS = 512;

function bounded(value: string, maximum: number): string {
  const characters = [...value];
  return characters.length <= maximum ? value : characters.slice(0, maximum).join("");
}

export type HerdrSidebarAction =
  | { readonly kind: "search" }
  | { readonly kind: "new" }
  | { readonly kind: "project-picker" }
  | { readonly kind: "project"; readonly id: string }
  | { readonly kind: "thread"; readonly id: string }
  | { readonly kind: "section"; readonly id: string }
  | { readonly kind: "more"; readonly id: string };

function isAction(value: unknown): value is HerdrSidebarAction {
  if (!value || typeof value !== "object" || !("kind" in value)) return false;
  const action = value as { readonly kind?: unknown; readonly id?: unknown };
  if (action.kind === "search" || action.kind === "new" || action.kind === "project-picker") {
    return true;
  }
  return (
    (action.kind === "project" ||
      action.kind === "thread" ||
      action.kind === "section" ||
      action.kind === "more") &&
    typeof action.id === "string" &&
    action.id.length > 0
  );
}

export function encodeHerdrSidebarAction(action: HerdrSidebarAction): string {
  const payload = NodeBuffer.Buffer.from(JSON.stringify(action), "utf8").toString("base64url");
  return `${ACTION_PREFIX}${payload}${ACTION_SUFFIX}`;
}

export function decodeHerdrSidebarAction(input: string): HerdrSidebarAction | null {
  if (!input.startsWith(ACTION_PREFIX) || !input.endsWith(ACTION_SUFFIX)) return null;
  try {
    const payload = input.slice(ACTION_PREFIX.length, -ACTION_SUFFIX.length);
    const action: unknown = JSON.parse(
      NodeBuffer.Buffer.from(payload, "base64url").toString("utf8"),
    );
    return isAction(action) ? action : null;
  } catch {
    return null;
  }
}

function statusForThread(status: ThreadStatus): HerdrAgentStatus {
  switch (status.key) {
    case "working":
    case "connecting":
      return "working";
    case "pending-approval":
    case "awaiting-input":
    case "plan-ready":
    case "error":
      return "blocked";
    case "completed":
      return "done";
    case "ready":
    case "idle":
    default:
      return "idle";
  }
}

function selectedToken(selection: Selection | null, kind: Selection["kind"], id: string): string {
  return selection?.kind === kind && selection.id === id ? "1" : "0";
}

export function buildHerdrSidebarItems(input: {
  readonly rows: ReadonlyArray<Row>;
  readonly selection: Selection | null;
  readonly projectScopeLabel: string;
}): Array<Omit<HerdrAgentViewItem, "targetPaneId">> {
  let order = 0;
  const item = (
    id: string,
    label: string,
    status: HerdrAgentStatus,
    project: string,
    action: HerdrSidebarAction,
    selected: string,
  ): Omit<HerdrAgentViewItem, "targetPaneId"> => ({
    id,
    label: bounded(label, 160),
    status,
    seen: true,
    tokens: {
      project: bounded(project, 80),
      selected,
      t3_order: String(order++).padStart(6, "0"),
    },
    activationInput: encodeHerdrSidebarAction(action),
  });

  const items = [
    item(
      "action:search",
      "Search projects and threads",
      "idle",
      "T3 Code",
      { kind: "search" },
      "0",
    ),
    item("action:new", "New thread", "idle", "T3 Code", { kind: "new" }, "0"),
    item(
      "action:project-picker",
      `Project · ${input.projectScopeLabel}`,
      "idle",
      "T3 Code",
      { kind: "project-picker" },
      "0",
    ),
  ];
  for (const row of input.rows) {
    if (row.kind === "section") {
      items.push(
        item(
          `section:${row.id}`,
          `${row.expanded ? "▾" : "▸"} ${row.title} (${row.count})`,
          "idle",
          row.title,
          { kind: "section", id: row.id },
          selectedToken(input.selection, "section", row.id),
        ),
      );
      continue;
    }
    if (row.kind === "thread") {
      items.push(
        item(
          `thread:${row.id}`,
          `${row.thread.title} · ${row.projectTitle}`,
          statusForThread(resolveThreadStatus(row.thread)),
          row.section === "active" ? "Active" : row.section === "snoozed" ? "Snoozed" : "Settled",
          { kind: "thread", id: row.id },
          selectedToken(input.selection, "thread", row.id),
        ),
      );
      continue;
    }
    if (row.kind === "more") {
      items.push(
        item(
          `more:${row.id}`,
          `Show ${row.hiddenCount} more`,
          "idle",
          "Settled",
          { kind: "more", id: row.id },
          selectedToken(input.selection, "more", row.id),
        ),
      );
    }
  }
  return items.slice(0, MAX_VIEW_ITEMS);
}
