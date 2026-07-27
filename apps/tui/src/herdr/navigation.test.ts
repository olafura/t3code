import { describe, expect, test } from "bun:test";

import type { OrchestrationShellSnapshot } from "../connection.ts";
import { buildRows, herdrSpaceExpansionKey } from "../components/Sidebar.logic.ts";
import type { HerdrSessionSnapshot } from "./protocol.ts";

const shell = {
  snapshotSequence: 1,
  updatedAt: "2026-07-27T00:00:00.000Z",
  projects: [
    {
      id: "project-repo",
      title: "repo",
      workspaceRoot: "/work/repo",
      defaultModelSelection: null,
      scripts: [],
      createdAt: "2026-07-27T00:00:00.000Z",
      updatedAt: "2026-07-27T00:00:00.000Z",
    },
    {
      id: "project-other",
      title: "other",
      workspaceRoot: "/work/other",
      defaultModelSelection: null,
      scripts: [],
      createdAt: "2026-07-27T00:00:00.000Z",
      updatedAt: "2026-07-27T00:00:00.000Z",
    },
  ],
  threads: [
    {
      id: "thread-repo",
      projectId: "project-repo",
      title: "Build the plugin",
      modelSelection: { instanceId: "codex", model: "gpt-5" },
      runtimeMode: "full-access",
      interactionMode: "default",
      branch: null,
      worktreePath: null,
      latestTurn: null,
      createdAt: "2026-07-27T00:00:00.000Z",
      updatedAt: "2026-07-27T00:00:00.000Z",
      archivedAt: null,
      settledOverride: null,
      settledAt: null,
      deletedAt: null,
      session: null,
      latestUserMessageAt: null,
      hasPendingApprovals: false,
      hasPendingUserInput: false,
      hasActionableProposedPlan: false,
    },
  ],
} as unknown as OrchestrationShellSnapshot;

const herdr = {
  version: "0.7.5",
  protocol: 17,
  workspaces: [
    {
      workspace_id: "w1",
      number: 1,
      label: "repo space",
      focused: true,
      pane_count: 2,
      tab_count: 1,
      active_tab_id: "w1:t1",
      agent_status: "working",
      worktree: {
        repo_key: "repo",
        repo_name: "repo",
        repo_root: "/work/repo",
        checkout_path: "/work/repo",
        is_linked_worktree: false,
      },
    },
  ],
  tabs: [],
  panes: [],
  layouts: [],
  agents: [
    {
      pane_id: "w1:p2",
      terminal_id: "term-2",
      workspace_id: "w1",
      tab_id: "w1:t1",
      focused: false,
      agent_status: "blocked",
      revision: 3,
      agent: "codex",
      name: "reviewer",
      cwd: "/work/repo",
    },
  ],
} as const satisfies HerdrSessionSnapshot;

describe("Herdr sidebar rows", () => {
  test("puts spaces first and nests matching threads and agents", () => {
    const rows = buildRows(
      shell,
      new Set([herdrSpaceExpansionKey("w1")]),
      new Set(),
      null,
      "",
      herdr,
    );

    expect(rows.map((row) => `${row.kind}:${row.id}`)).toEqual([
      "space:w1",
      "thread:thread-repo",
      "agent:w1:p2",
      "project:project-other",
    ]);
  });

  test("filters by native agent name without losing its space", () => {
    const rows = buildRows(shell, new Set(), new Set(), null, "review", herdr);

    expect(rows.map((row) => `${row.kind}:${row.id}`)).toEqual(["space:w1", "agent:w1:p2"]);
  });
});
