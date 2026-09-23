import {
  OrchestrationV2DomainEvent,
  OrchestrationV2ThreadProjection,
  type OrchestrationV2ThreadStreamItem,
  type ThreadId,
} from "@t3tools/contracts";
import { isOrchestrationV2TurnItemVisible } from "@t3tools/shared/orchestrationV2Timeline";
import * as DateTime from "effect/DateTime";
import * as Schema from "effect/Schema";

import { applyPatch, type Patch } from "./patch.ts";

/** One protocol-3 stream event: `[seq, kind, entityId, patch, atMillis]`. */
export type ShapeEvent = readonly [number, string, string, Patch, number];
/** One protocol-3 snapshot row: `[kind, entityId, entity]`. */
export type ShapeRow = readonly [string, string, Record<string, unknown>];

type EntityJson = Record<string, unknown>;

// Projection array for each entity kind; "thread" is the projection's own record.
const PROJECTION_FIELD = {
  run: "runs",
  "run-attempt": "attempts",
  node: "nodes",
  subagent: "subagents",
  "provider-session": "providerSessions",
  "provider-thread": "providerThreads",
  "provider-turn": "providerTurns",
  "runtime-request": "runtimeRequests",
  message: "messages",
  plan: "plans",
  "turn-item": "turnItems",
  "checkpoint-scope": "checkpointScopes",
  checkpoint: "checkpoints",
  "context-handoff": "contextHandoffs",
  "context-transfer": "contextTransfers",
} as const;

// The v2 domain event that carries a whole entity of each kind.
const UPSERT_EVENT: Record<string, string> = {
  thread: "thread.metadata-updated",
  "checkpoint-scope": "checkpoint-scope.created",
  checkpoint: "checkpoint.captured",
};

// Entities arrive as JSON, so decode through the contracts' JSON codecs.
const isoMillis = (ms: number) => DateTime.formatIso(DateTime.makeUnsafe(ms));

const decodeProjection = Schema.decodeUnknownSync(
  Schema.toCodecJson(OrchestrationV2ThreadProjection),
);
const decodeEvent = Schema.decodeUnknownSync(Schema.toCodecJson(OrchestrationV2DomainEvent));

/**
 * Folds one protocol-3 thread shape into the v2 stream items the thread state
 * already consumes, so the existing reducer, caches and UI work unchanged.
 *
 * The server sends entities and patches; this keeps the current entity per id
 * (insertion order is creation order), emits a v2 `snapshot` when a snapshot
 * completes, and turns each patch into the v2 upsert event for that entity.
 */
export class ThreadShapeFold {
  private readonly entities = new Map<string, Map<string, EntityJson>>();
  private updatedAt = 0;
  private readonly threadId: ThreadId;

  constructor(threadId: ThreadId) {
    this.threadId = threadId;
  }

  snapshot(input: {
    readonly rows: ReadonlyArray<ShapeRow>;
    readonly part: number;
    readonly done: boolean;
    readonly offset: number;
    /** Time of the stream's latest event, unix ms. */
    readonly at: number | null;
  }): ReadonlyArray<OrchestrationV2ThreadStreamItem> {
    if (input.part === 0) {
      this.entities.clear();
      this.updatedAt = input.at ?? 0;
    }
    for (const [kind, id, entity] of input.rows) this.byKind(kind).set(id, entity);
    if (!input.done) return [];
    const projection = this.projection();
    return projection === null
      ? []
      : [{ kind: "snapshot", snapshotSequence: input.offset, projection }];
  }

  events(events: ReadonlyArray<ShapeEvent>): ReadonlyArray<OrchestrationV2ThreadStreamItem> {
    const items: Array<OrchestrationV2ThreadStreamItem> = [];
    for (const [seq, kind, id, patch, at] of events) {
      const byKind = this.byKind(kind);
      const entity = applyPatch(byKind.get(id), patch);
      // Map order is creation order: updates keep their slot, while a deleted or
      // replaced entity is appended again, as in the server projection.
      if (entity === null || patch.d === true) byKind.delete(id);
      if (entity !== null) byKind.set(id, entity);
      this.updatedAt = Math.max(this.updatedAt, at);
      const event = this.domainEvent(seq, kind, id, entity, patch, at);
      if (event !== null) items.push({ kind: "event", sequence: seq, event });
    }
    return items;
  }

  private byKind(kind: string): Map<string, EntityJson> {
    let byKind = this.entities.get(kind);
    if (byKind === undefined) {
      byKind = new Map();
      this.entities.set(kind, byKind);
    }
    return byKind;
  }

  private projection(): OrchestrationV2ThreadProjection | null {
    const thread = this.entities.get("thread")?.get(this.threadId);
    if (thread === undefined) return null;
    const encoded: Record<string, unknown> = {
      thread,
      visibleTurnItems: [],
      updatedAt: isoMillis(this.updatedAt),
    };
    for (const [kind, field] of Object.entries(PROJECTION_FIELD)) {
      encoded[field] = [...(this.entities.get(kind)?.values() ?? [])];
    }
    // Turn items are shown in ordinal order, as the reference server sends them.
    encoded.turnItems = (encoded.turnItems as ReadonlyArray<EntityJson>).toSorted(
      (left, right) =>
        Number(left.ordinal) - Number(right.ordinal) ||
        String(left.id).localeCompare(String(right.id)),
    );
    const projection = decodeProjection(encoded);
    // Unforked threads show their own visible items; forks need the source thread.
    const visibleTurnItems = projection.turnItems
      .filter((item) =>
        isOrchestrationV2TurnItemVisible({
          item,
          runs: projection.runs,
          attempts: projection.attempts,
          items: projection.turnItems,
        }),
      )
      .map((item, position) => ({
        position,
        visibility: "local" as const,
        sourceThreadId: item.threadId,
        sourceItemId: item.id,
        item,
      }));
    return { ...projection, visibleTurnItems };
  }

  private domainEvent(
    seq: number,
    kind: string,
    id: string,
    entity: EntityJson | null,
    patch: Patch,
    at: number,
  ): OrchestrationV2DomainEvent | null {
    if (kind === "project") return null;
    const base = {
      id: `v3:${seq}`,
      threadId: this.threadId,
      occurredAt: isoMillis(at),
    };
    if (entity === null) {
      // Only provider sessions are removed from a thread (detached); nothing else is.
      return kind === "provider-session"
        ? decodeEvent({
            ...base,
            type: "provider-session.detached",
            payload: { providerSessionId: id, detachedAt: base.occurredAt },
          })
        : null;
    }
    if (kind === "thread" && patch.s?.deletedAt != null) {
      return decodeEvent({ ...base, type: "thread.deleted", payload: entity });
    }
    return decodeEvent({ ...base, type: UPSERT_EVENT[kind] ?? `${kind}.updated`, payload: entity });
  }
}
