import { describe, expect, test } from "bun:test";

import type { Row } from "../components/Sidebar.logic.ts";
import {
  buildHerdrSidebarItems,
  decodeHerdrSidebarAction,
  encodeHerdrSidebarAction,
} from "./sidebar.ts";

describe("Herdr native T3 sidebar", () => {
  test("round-trips private activation sequences without accepting ordinary input", () => {
    const sequence = encodeHerdrSidebarAction({ kind: "thread", id: "thread-1" });

    expect(decodeHerdrSidebarAction(sequence)).toEqual({ kind: "thread", id: "thread-1" });
    expect(decodeHerdrSidebarAction("hello")).toBeNull();
    expect(decodeHerdrSidebarAction("\u001bP+t3-sidebar;garbage\u001b\\")).toBeNull();
  });

  test("builds the complete flat lifecycle navigation model", () => {
    const rows: Row[] = [
      {
        kind: "section",
        id: "sidebar-v2:snoozed",
        section: "snoozed",
        title: "Snoozed",
        count: 1,
        expanded: true,
      },
      {
        kind: "thread",
        id: "thread-1",
        thread: {
          id: "thread-1",
          title: "Fix native sidebar",
          session: { status: "running" },
        } as never,
        section: "active",
        projectTitle: "t3code",
        timestamp: "2026-07-28T00:00:00.000Z",
      },
      {
        kind: "more",
        id: "sidebar-v2:settled",
        section: "settled",
        hiddenCount: 1,
      },
    ];

    const items = buildHerdrSidebarItems({
      rows,
      selection: { kind: "thread", id: "thread-1" },
    });

    expect(items.map((item) => item.id)).toEqual([
      "action:search",
      "action:new",
      "section:sidebar-v2:snoozed",
      "thread:thread-1",
      "more:sidebar-v2:settled",
    ]);
    expect(items[2]).toMatchObject({
      label: "▾ Snoozed (1)",
      tokens: { project: "Snoozed" },
    });
    expect(items[3]).toMatchObject({
      label: "Fix native sidebar · t3code",
      status: "working",
      tokens: { project: "Active", selected: "1" },
    });
    expect(decodeHerdrSidebarAction(items[4]?.activationInput ?? "")).toEqual({
      kind: "more",
      id: "sidebar-v2:settled",
    });
  });

  test("publishes the same project filter used by the standalone sidebar", () => {
    const items = buildHerdrSidebarItems({
      rows: [],
      selection: null,
      projects: [
        { id: "p1", title: "t3code" },
        { id: "p2", title: "herdr" },
      ],
      projectScopeId: "p1",
    });

    expect(items.slice(2).map((item) => item.label)).toEqual(["All projects", "✓ t3code", "herdr"]);
    expect(decodeHerdrSidebarAction(items[2]?.activationInput ?? "")).toEqual({
      kind: "project",
      id: "__all__",
    });
  });
});
