import {
  OrchestrationV2AppThread,
  OrchestrationV2TurnItem,
  type OrchestrationV2ThreadProjection,
} from "@t3tools/contracts";
import * as Schema from "effect/Schema";
import { describe, expect, it } from "vite-plus/test";

import { applyOrchestrationV2ProjectionEvent } from "../state/orchestrationV2Projection.ts";
import { v2Projection, v2ThreadId } from "../state/orchestrationV2TestFixtures.ts";
import { ThreadShapeFold, type ShapeRow } from "./threadShape.ts";

const thread = Schema.encodeSync(Schema.toCodecJson(OrchestrationV2AppThread))(
  v2Projection.thread,
) as Record<string, unknown>;

const message = (text: string) =>
  Schema.encodeSync(Schema.toCodecJson(OrchestrationV2TurnItem))({
    id: "item-1",
    threadId: v2ThreadId,
    runId: null,
    nodeId: null,
    providerThreadId: null,
    providerTurnId: null,
    nativeItemRef: null,
    parentItemId: null,
    ordinal: 1,
    status: "running",
    title: null,
    startedAt: v2Projection.updatedAt,
    completedAt: null,
    updatedAt: v2Projection.updatedAt,
    type: "assistant_message",
    messageId: "message-1",
    text,
    streaming: true,
  } as unknown as OrchestrationV2TurnItem) as Record<string, unknown>;

function fold(
  items: ReturnType<ThreadShapeFold["events"]>,
  start: OrchestrationV2ThreadProjection,
) {
  return items.reduce<OrchestrationV2ThreadProjection | null>(
    (projection, item) =>
      item.kind === "event"
        ? applyOrchestrationV2ProjectionEvent(projection, item.event)
        : projection,
    start,
  );
}

describe("ThreadShapeFold", () => {
  it("builds the v2 projection from a snapshot split across parts", () => {
    const shape = new ThreadShapeFold(v2ThreadId);
    const rows: ShapeRow[] = [
      ["thread", v2ThreadId, thread],
      ["turn-item", "item-1", message("Hello")],
    ];
    expect(
      shape.snapshot({ rows: rows.slice(0, 1), part: 0, done: false, offset: 9, at: 1 }),
    ).toEqual([]);
    const [item] = shape.snapshot({ rows: rows.slice(1), part: 1, done: true, offset: 9, at: 1 });

    expect(item?.kind).toBe("snapshot");
    if (item?.kind !== "snapshot") return;
    expect(item.snapshotSequence).toBe(9);
    expect(item.projection.thread.title).toBe(v2Projection.thread.title);
    expect(item.projection.turnItems.map((i) => i.id)).toEqual(["item-1"]);
    expect(item.projection.visibleTurnItems).toHaveLength(1);
  });

  it("turns streamed text patches into upserts the existing reducer applies", () => {
    const shape = new ThreadShapeFold(v2ThreadId);
    const [snapshot] = shape.snapshot({
      rows: [
        ["thread", v2ThreadId, thread],
        ["turn-item", "item-1", message("Hel")],
      ],
      part: 0,
      done: true,
      offset: 1,
      at: 1,
    });
    if (snapshot?.kind !== "snapshot") throw new Error("expected snapshot");

    const items = shape.events([
      [2, "turn-item", "item-1", { a: { text: "lo" } }, Date.parse("2026-06-20T00:00:01Z")],
      [
        3,
        "turn-item",
        "item-1",
        { a: { text: ", world" }, s: { status: "completed" } },
        Date.parse("2026-06-20T00:00:02Z"),
      ],
    ]);

    expect(items.map((i) => (i.kind === "event" ? [i.sequence, i.event.type] : i.kind))).toEqual([
      [2, "turn-item.updated"],
      [3, "turn-item.updated"],
    ]);
    const projection = fold(items, snapshot.projection);
    const [turnItem] = projection?.turnItems ?? [];
    expect(turnItem?.type === "assistant_message" && turnItem.text).toBe("Hello, world");
    expect(turnItem?.status).toBe("completed");
  });

  it("a deleted thread becomes the v2 delete event", () => {
    const shape = new ThreadShapeFold(v2ThreadId);
    shape.snapshot({
      rows: [["thread", v2ThreadId, thread]],
      part: 0,
      done: true,
      offset: 1,
      at: 1,
    });
    const [item] = shape.events([
      [
        2,
        "thread",
        v2ThreadId,
        { s: { deletedAt: "2026-06-21T00:00:00.000Z" } },
        Date.parse("2026-06-21T00:00:00Z"),
      ],
    ]);
    expect(item?.kind === "event" && item.event.type).toBe("thread.deleted");
  });
});

describe("ThreadShapeFold deletes", () => {
  it("a deleted provider session becomes the v2 detach event and leaves the projection", () => {
    const shape = new ThreadShapeFold(v2ThreadId);
    shape.snapshot({
      rows: [["thread", v2ThreadId, thread]],
      part: 0,
      done: true,
      offset: 1,
      at: 1,
    });
    const [item] = shape.events([
      [2, "provider-session", "ps-1", { d: true }, Date.parse("2026-06-21T00:00:00Z")],
    ]);
    expect(item?.kind === "event" && item.event.type).toBe("provider-session.detached");
  });
});

describe("ThreadShapeFold order", () => {
  it("updates keep an entity's place in creation order", () => {
    const shape = new ThreadShapeFold(v2ThreadId);
    const item = (id: string, ordinal: number) => ({ ...message("x"), id, ordinal });
    shape.snapshot({
      rows: [
        ["thread", v2ThreadId, thread],
        ["turn-item", "a", item("a", 1)],
        ["turn-item", "b", item("b", 2)],
      ],
      part: 0,
      done: true,
      offset: 1,
      at: 1,
    });
    shape.events([[2, "turn-item", "a", { a: { text: "y" } }, 2]]);
    const [snapshot] = shape.snapshot({ rows: [], part: 1, done: true, offset: 2, at: 2 });
    expect(snapshot?.kind === "snapshot" && snapshot.projection.turnItems.map((i) => i.id)).toEqual(
      ["a", "b"],
    );
  });
});

describe("ThreadShapeFold turn item order", () => {
  it("shows turn items by ordinal whatever order the rows arrive in", () => {
    const shape = new ThreadShapeFold(v2ThreadId);
    const item = (id: string, ordinal: number) => ({ ...message("x"), id, ordinal });
    const [snapshot] = shape.snapshot({
      rows: [
        ["thread", v2ThreadId, thread],
        ["turn-item", "late", item("late", 2)],
        ["turn-item", "first", item("first", 0)],
        ["turn-item", "middle", item("middle", 1)],
      ],
      part: 0,
      done: true,
      offset: 1,
      at: 1,
    });
    expect(
      snapshot?.kind === "snapshot" &&
        snapshot.projection.visibleTurnItems.map((row) => row.item.id),
    ).toEqual(["first", "middle", "late"]);
  });
});
