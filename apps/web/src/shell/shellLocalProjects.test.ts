import { EnvironmentId, ProjectId } from "@t3tools/contracts";
import { describe, expect, it } from "vite-plus/test";
import type { SidebarProjectSnapshot } from "../sidebarProjectGrouping";
import { buildShellLocalProjects, resolveShellLocalEnvironmentId } from "./shellLocalProjects";

const local = EnvironmentId.make("local");
const remote = EnvironmentId.make("remote");
const member = (environmentId: EnvironmentId, id: string, workspaceRoot: string) => ({
  environmentId,
  id: ProjectId.make(id),
  workspaceRoot,
  title: id,
  physicalProjectKey: `${environmentId}:${workspaceRoot}`,
  environmentLabel: null,
  defaultModelSelection: null,
  scripts: [],
  createdAt: "2026-09-08T00:00:00Z",
  updatedAt: "2026-09-08T00:00:00Z",
});
const groups: ReadonlyArray<SidebarProjectSnapshot> = [
  {
    ...member(remote, "remote", "/remote/repo"),
    projectKey: "grouped",
    displayName: "Grouped project",
    groupedProjectCount: 3,
    environmentPresence: "mixed",
    allRemoteMembersAreDesktopLocal: false,
    allRemoteMembersAreWsl: false,
    memberProjectRefs: [],
    remoteEnvironmentLabels: [],
    memberProjects: [
      member(remote, "remote", "/remote/repo"),
      member(local, "main", "/local/repo"),
      member(local, "checkout", "/local/checkout"),
    ],
  },
];

describe("shell local projects", () => {
  it("publishes every physical local checkout even when the group representative is remote", () => {
    expect(buildShellLocalProjects(groups, local)).toEqual([
      {
        key: "local:main",
        logicalProjectKey: "grouped",
        displayName: "main",
        environmentId: local,
        projectId: "main",
        workspaceRoot: "/local/repo",
      },
      {
        key: "local:checkout",
        logicalProjectKey: "grouped",
        displayName: "checkout",
        environmentId: local,
        projectId: "checkout",
        workspaceRoot: "/local/checkout",
      },
    ]);
  });

  it("clears all filesystem context without a connected local primary environment", () => {
    expect(buildShellLocalProjects(groups, null)).toEqual([]);
    for (const input of [
      { hostname: "localhost", connected: false, primaryEnvironmentId: local },
      { hostname: "remote.example", connected: true, primaryEnvironmentId: local },
      { hostname: "localhost", connected: true, primaryEnvironmentId: null },
    ])
      expect(resolveShellLocalEnvironmentId(input)).toBeNull();
  });

  it.each(["localhost", "127.0.0.1", "[::1]"])(
    "recognizes loopback host %s, subject to native permission",
    (hostname) => {
      expect(
        resolveShellLocalEnvironmentId({ hostname, connected: true, primaryEnvironmentId: local }),
      ).toBe(local);
    },
  );
});
