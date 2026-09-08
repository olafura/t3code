/** Independent Qt clients share authentication, but not whole-store UI snapshots. */
export function appViewStorageKey(key: string): string {
  const id = typeof window === "undefined" ? undefined : window.__t3AppViewStorageId;
  return typeof id === "string" && id.length > 0
    ? `t3code:app-view:${encodeURIComponent(id)}:${key}`
    : key;
}
