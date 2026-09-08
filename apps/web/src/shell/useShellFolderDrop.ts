import type { EnvironmentId } from "@t3tools/contracts";
import { useRef } from "react";

export interface ShellFolderOpenRequest {
  readonly environmentId: EnvironmentId;
  readonly rawCwd: string;
  readonly platform: string;
  readonly currentProjectCwd: null;
  readonly createWorkspaceRootIfMissing: false;
}

/** Native paths belong to the primary local environment, not the active thread. */
export function useShellFolderDrop(input: {
  readonly primaryEnvironmentId: EnvironmentId | null;
  readonly platform: string;
  readonly connected: boolean;
  readonly open: (request: ShellFolderOpenRequest) => Promise<void>;
  readonly onError: (error: unknown) => void;
}) {
  const pending = useRef(false);
  return async (path: string) => {
    if (pending.current) return;
    const environmentId = input.primaryEnvironmentId;
    if (
      !input.connected ||
      environmentId === null ||
      !["localhost", "127.0.0.1", "[::1]"].includes(window.location.hostname)
    ) {
      input.onError(new Error("Folder drops require a connected local primary environment."));
      return;
    }
    // QML canonicalizes the directory. Never resolve relative paths against
    // whichever project happens to be selected.
    if (!/^(?:\/|[a-zA-Z]:[\\/])/.test(path) || path.includes("\0")) {
      input.onError(new Error("Drop an existing folder using its absolute local path."));
      return;
    }
    pending.current = true;
    await Promise.resolve()
      .then(() =>
        input.open({
          environmentId,
          rawCwd: path,
          platform: input.platform,
          currentProjectCwd: null,
          createWorkspaceRootIfMissing: false,
        }),
      )
      .catch(input.onError)
      .finally(() => {
        pending.current = false;
      });
  };
}
