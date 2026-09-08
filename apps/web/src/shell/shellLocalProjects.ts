import type { EnvironmentId } from "@t3tools/contracts";
import type { ShellLocalProject } from "@t3tools/contracts/shell";
import type { SidebarProjectSnapshot } from "../sidebarProjectGrouping";

/** Loopback is necessary, not sufficient: native also gates forwarded localhost URLs. */
export function resolveShellLocalEnvironmentId(input: {
  primaryEnvironmentId: EnvironmentId | null;
  connected: boolean;
  hostname: string;
}): EnvironmentId | null {
  return input.connected && ["localhost", "127.0.0.1", "[::1]"].includes(input.hostname)
    ? input.primaryEnvironmentId
    : null;
}

/** Group representatives omit physical checkouts; filesystem guards need every local root. */
export function buildShellLocalProjects(
  groups: ReadonlyArray<SidebarProjectSnapshot>,
  localEnvironmentId: EnvironmentId | null,
): ReadonlyArray<ShellLocalProject> {
  if (localEnvironmentId === null) return [];
  return groups.flatMap((group) =>
    group.memberProjects
      .filter((member) => member.environmentId === localEnvironmentId)
      .map((member) => ({
        key: `${member.environmentId}:${member.id}`,
        logicalProjectKey: group.projectKey,
        displayName: member.title,
        environmentId: member.environmentId,
        projectId: member.id,
        workspaceRoot: member.workspaceRoot,
      })),
  );
}
