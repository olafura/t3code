type Listener = () => void;
const listeners = new Map<string, Listener>();
let pending: { projectKey: string } | null = null;

/** Hands one physical checkout to the existing settings confirmation, never a whole group. */
export function requestShellProjectRemoval(projectKey: string): () => void {
  const request = { projectKey };
  const listener = listeners.get(projectKey);
  if (listener) {
    pending = null;
    listener();
  } else {
    pending = request;
  }
  return () => {
    if (pending === request) pending = null;
  };
}

export function subscribeShellProjectRemovalRequests(
  targets: ReadonlyArray<{ projectKey: string; confirm: Listener }>,
): () => void {
  for (const target of targets) listeners.set(target.projectKey, target.confirm);
  const request = pending;
  pending = null;
  if (request) targets.find((target) => target.projectKey === request.projectKey)?.confirm();
  return () => {
    for (const target of targets) {
      if (listeners.get(target.projectKey) === target.confirm) listeners.delete(target.projectKey);
    }
  };
}
