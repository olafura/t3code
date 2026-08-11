import type { ThreadId } from "@t3tools/contracts";

/**
 * Opaque, exclusive cursor for windowed thread detail reads. Two shapes:
 *
 * - An "items" cursor encodes the keyset boundary of an already-delivered
 *   page of local turn items: the boundary item's `(ordinal, turn_item_id)`.
 *   Passing it back requests the adjacent disjoint slice of strictly older
 *   items under that ordering. The pair is derived from event content (the
 *   projector writes the event's ordinal), so cursors survive projection
 *   rebuilds; it is served directly by the
 *   `(thread_id, ordinal, turn_item_id)` index.
 * - An "inherited" cursor marks that local history is exhausted and the next
 *   (final) page should carry the fork's inherited prefix — the source
 *   thread's visible items plus the synthetic fork marker. Non-fork threads
 *   never produce one.
 *
 * The thread id is embedded so a cursor can never be replayed against a
 * different thread. Clients must treat the string as opaque.
 */
export type ThreadDetailPageCursor =
  | {
      readonly kind: "items";
      readonly threadId: ThreadId;
      readonly beforeOrdinal: number;
      readonly beforeTurnItemId: string;
    }
  | {
      readonly kind: "inherited";
      readonly threadId: ThreadId;
    };

export function encodeThreadDetailPageCursor(cursor: ThreadDetailPageCursor): string {
  const payload =
    cursor.kind === "inherited"
      ? { t: cursor.threadId, h: 1 }
      : { t: cursor.threadId, o: cursor.beforeOrdinal, i: cursor.beforeTurnItemId };
  return Buffer.from(JSON.stringify(payload)).toString("base64url");
}

/**
 * Returns null for anything that is not a well-formed cursor. Callers degrade
 * a malformed or foreign-thread cursor to a first-page request.
 */
export function decodeThreadDetailPageCursor(encoded: string): ThreadDetailPageCursor | null {
  let parsed: unknown;
  try {
    parsed = JSON.parse(Buffer.from(encoded, "base64url").toString("utf8"));
  } catch {
    return null;
  }
  if (parsed === null || typeof parsed !== "object") {
    return null;
  }
  const record = parsed as Record<string, unknown>;
  if (typeof record.t !== "string" || record.t.length === 0) {
    return null;
  }
  const threadId = record.t as ThreadId;
  if (record.h === 1) {
    return { kind: "inherited", threadId };
  }
  if (typeof record.o !== "number" || !Number.isSafeInteger(record.o) || record.o < 0) {
    return null;
  }
  if (typeof record.i !== "string" || record.i.length === 0) {
    return null;
  }
  return {
    kind: "items",
    threadId,
    beforeOrdinal: record.o,
    beforeTurnItemId: record.i,
  };
}
