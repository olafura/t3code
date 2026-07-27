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

  test("builds the complete visible project and thread navigation model", () => {
    const rows: Row[] = [
      {
        kind: "project",
        id: "project-1",
        title: "t3code",
        count: 2,
        status: null,
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
      },
      { kind: "more", id: "project-1", hiddenCount: 1 },
    ];

    const items = buildHerdrSidebarItems({
      rows,
      selection: { kind: "thread", id: "thread-1" },
    });

    expect(items.map((item) => item.id)).toEqual([
      "action:search",
      "action:new",
      "project:project-1",
      "thread:thread-1",
      "more:project-1",
    ]);
    expect(items[2]).toMatchObject({
      label: "▾ t3code (2)",
      tokens: { project: "Projects" },
    });
    expect(items[3]).toMatchObject({
      label: "Fix native sidebar",
      status: "working",
      tokens: { project: "t3code", selected: "1" },
    });
    expect(decodeHerdrSidebarAction(items[4]?.activationInput ?? "")).toEqual({
      kind: "more",
      id: "project-1",
    });
  });
});
