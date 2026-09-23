/**
 * A protocol-3 entity patch: changed fields (`s`), string suffixes appended to
 * existing fields (`a`, streamed text and output), removed fields (`u`), and `d`
 * to remove the entity first (alone it deletes; with `s` it replaces).
 * Mirrors `T3.Patch` on the server.
 */
export interface Patch {
  readonly s?: Readonly<Record<string, unknown>>;
  readonly a?: Readonly<Record<string, string>>;
  readonly u?: ReadonlyArray<string>;
  readonly d?: true;
}

/** Returns the patched entity, or `null` when the patch deletes it. */
export function applyPatch(
  entity: Readonly<Record<string, unknown>> | undefined,
  patch: Patch,
): Record<string, unknown> | null {
  if (patch.d === true && patch.s === undefined && patch.a === undefined) return null;
  const next: Record<string, unknown> = { ...(patch.d === true ? {} : entity), ...patch.s };
  for (const field of patch.u ?? []) delete next[field];
  for (const [field, suffix] of Object.entries(patch.a ?? {})) {
    const current = next[field];
    next[field] = typeof current === "string" ? current + suffix : suffix;
  }
  return next;
}
