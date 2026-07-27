import { describe, expect, test } from "bun:test";

import { createHerdrTuiHost, herdrWorkspaceCwd } from "./host.ts";
import type {
  HerdrAgentInfo,
  HerdrPaneInfo,
  HerdrPaneReadResult,
  HerdrSessionSnapshot,
} from "./protocol.ts";

function snapshot(
  panes: ReadonlyArray<HerdrPaneInfo> = [],
  overrides: Partial<HerdrSessionSnapshot> = {},
): HerdrSessionSnapshot {
  return {
    version: "0.7.5",
    protocol: 17,
    workspaces: [
      {
        workspace_id: "w1",
        number: 1,
        label: "repo",
        focused: true,
        pane_count: panes.length,
        tab_count: 1,
        active_tab_id: "w1:t1",
        agent_status: "idle",
      },
    ],
    tabs: [],
    panes,
    layouts: [
      {
        workspace_id: "w1",
        tab_id: "w1:t1",
        focused_pane_id: "w1:p1",
        zoomed: false,
      },
    ],
    agents: [],
    ...overrides,
  };
}

function fakeProtocol(initial: HerdrSessionSnapshot) {
  let current = initial;
  const calls: Array<{ readonly method: string; readonly value: unknown }> = [];
  return {
    calls,
    setSnapshot: (next: HerdrSessionSnapshot) => {
      current = next;
    },
    connect: async () => {},
    ping: async () => ({ version: "0.7.5", protocol: 17 }),
    snapshot: async () => current,
    subscribeToLifecycleEvents: async () => {},
    onEvent: () => () => {},
    onDisconnect: () => () => {},
    readAgent: async () =>
      ({
        pane_id: "w1:p2",
        workspace_id: "w1",
        tab_id: "w1:t1",
        source: "recent_unwrapped",
        format: "text",
        text: "done",
        revision: 1,
        truncated: false,
      }) satisfies HerdrPaneReadResult,
    promptAgent: async () => ({}) as HerdrAgentInfo,
    focusAgent: async (target: string) => {
      calls.push({ method: "agent.focus", value: target });
    },
    sendAgentKeys: async (target: string, keys: ReadonlyArray<string>) => {
      calls.push({ method: "agent.send_keys", value: { target, keys } });
    },
    focusPane: async (paneId: string) => {
      calls.push({ method: "pane.focus", value: paneId });
    },
    splitPane: async (input: unknown) => {
      calls.push({ method: "pane.split", value: input });
      const pane: HerdrPaneInfo = {
        pane_id: "w1:p3",
        terminal_id: "term-3",
        workspace_id: "w1",
        tab_id: "w1:t1",
        focused: true,
        agent_status: "unknown",
        revision: 0,
        cwd: "/repo/worktree",
      };
      current = snapshot([...current.panes, pane]);
      return pane;
    },
    reportPaneAgent: async (input: unknown) => {
      calls.push({ method: "pane.report_agent", value: input });
    },
    releasePaneAgent: async (input: unknown) => {
      calls.push({ method: "pane.release_agent", value: input });
    },
    reportPaneMetadata: async (input: unknown) => {
      calls.push({ method: "pane.report_metadata", value: input });
    },
    openPluginPane: async (input: unknown) => {
      calls.push({ method: "plugin.pane.open", value: input });
    },
    dispose: () => {},
  };
}

describe("createHerdrTuiHost", () => {
  test("reuses a pane linked by thread metadata", async () => {
    const protocol = fakeProtocol(
      snapshot([
        {
          pane_id: "w1:p8",
          terminal_id: "term-8",
          workspace_id: "w1",
          tab_id: "w1:t1",
          focused: false,
          agent_status: "unknown",
          revision: 0,
          tokens: { t3_thread_id: "thread-1", t3_terminal_index: "1" },
        },
      ]),
    );
    const host = createHerdrTuiHost(
      {
        socketPath: "/tmp/herdr.sock",
        paneId: "w1:p1",
        workspaceId: "w1",
        environmentKey: "local",
      },
      protocol as never,
    );
    host.start();
    await Promise.resolve();
    await host.openThreadTerminal({ threadId: "thread-1", title: "Fix it", cwd: "/repo" });

    expect(protocol.calls).toEqual([{ method: "pane.focus", value: "w1:p8" }]);
    host.dispose();
  });

  test("reports the selected T3 thread through Herdr's native agent model", async () => {
    const protocol = fakeProtocol(snapshot());
    const host = createHerdrTuiHost(
      {
        socketPath: "/tmp/herdr.sock",
        paneId: "w1:p1",
        workspaceId: "w1",
        pluginId: "dev.t3code",
        environmentKey: "local",
      },
      protocol as never,
    );

    await host.reportThread({
      threadId: "thread-1",
      title: "Fix terminal integration",
      state: "working",
    });

    expect(protocol.calls).toEqual([
      {
        method: "pane.report_agent",
        value: {
          paneId: "w1:p1",
          source: "plugin:dev.t3code",
          agent: "t3-code",
          state: "working",
          message: "Fix terminal integration",
          sessionId: "thread-1",
        },
      },
      {
        method: "pane.report_metadata",
        value: {
          paneId: "w1:p1",
          source: "plugin:dev.t3code",
          title: "Fix terminal integration",
          displayAgent: "T3 Code",
          tokens: { t3_thread_id: "thread-1", t3_environment: "local" },
        },
      },
    ]);
    host.dispose();
  });

  test("creates and labels a real split when no linked pane exists", async () => {
    const protocol = fakeProtocol(snapshot());
    const host = createHerdrTuiHost(
      {
        socketPath: "/tmp/herdr.sock",
        paneId: "w1:p1",
        workspaceId: "w1",
        environmentKey: "local",
      },
      protocol as never,
    );
    host.start();
    await Promise.resolve();
    await host.openThreadTerminal({
      threadId: "thread-2",
      title: "Build feature",
      cwd: "/repo/worktree",
    });

    expect(protocol.calls).toEqual([
      {
        method: "pane.split",
        value: {
          targetPaneId: "w1:p1",
          workspaceId: "w1",
          cwd: "/repo/worktree",
          direction: "down",
          ratio: 0.62,
        },
      },
      {
        method: "pane.report_agent",
        value: {
          paneId: "w1:p3",
          source: "plugin:dev.t3code",
          agent: "t3-terminal",
          state: "idle",
          message: "Terminal 1 · Build feature",
        },
      },
      {
        method: "pane.report_metadata",
        value: {
          paneId: "w1:p3",
          source: "plugin:dev.t3code",
          tokens: {
            t3_thread_id: "thread-2",
            t3_environment: "local",
            t3_terminal_index: "1",
          },
          title: "Terminal 1 · Build feature",
          displayAgent: "T3 Terminal",
        },
      },
    ]);
    host.dispose();
  });

  test("does not mistake the reporting dashboard for its thread terminal", async () => {
    const current = snapshot();
    const protocol = fakeProtocol({
      ...current,
      panes: current.panes.map((pane) =>
        pane.pane_id === "w1:p1" ? { ...pane, tokens: { t3_thread_id: "thread-dashboard" } } : pane,
      ),
    });
    const host = createHerdrTuiHost(
      {
        socketPath: "/tmp/herdr.sock",
        paneId: "w1:p1",
        workspaceId: "w1",
        environmentKey: "local",
      },
      protocol as never,
    );
    host.start();
    await Promise.resolve();

    await host.openThreadTerminal({
      threadId: "thread-dashboard",
      title: "Dashboard thread",
      cwd: "/repo/worktree",
    });

    expect(protocol.calls[0]).toEqual({
      method: "pane.split",
      value: {
        targetPaneId: "w1:p1",
        workspaceId: "w1",
        cwd: "/repo/worktree",
        direction: "down",
        ratio: 0.62,
      },
    });
    host.dispose();
  });

  test("falls back to the project when a thread worktree no longer exists", async () => {
    const protocol = fakeProtocol(snapshot());
    const host = createHerdrTuiHost(
      {
        socketPath: "/tmp/herdr.sock",
        paneId: "w1:p1",
        workspaceId: "w1",
        environmentKey: "local",
        isDirectory: async (path) => path === "/repo",
      },
      protocol as never,
    );
    host.start();
    await Promise.resolve();
    await host.openThreadTerminal({
      threadId: "thread-stale",
      title: "Old worktree",
      cwd: "/repo/.t3/worktrees/stale",
      fallbackCwd: "/repo",
    });

    expect(protocol.calls[0]).toEqual({
      method: "pane.split",
      value: {
        targetPaneId: "w1:p1",
        workspaceId: "w1",
        cwd: "/repo",
        direction: "down",
        ratio: 0.62,
      },
    });
    host.dispose();
  });

  test("creates and cycles multiple native terminal instances", async () => {
    const protocol = fakeProtocol(snapshot());
    const host = createHerdrTuiHost(
      {
        socketPath: "/tmp/herdr.sock",
        paneId: "w1:p1",
        workspaceId: "w1",
        environmentKey: "local",
      },
      protocol as never,
    );
    host.start();
    await Promise.resolve();
    const input = {
      threadId: "thread-many",
      title: "Multiple terminals",
      cwd: "/repo",
    } as const;

    await host.createThreadTerminal(input);
    protocol.setSnapshot(
      snapshot([
        {
          pane_id: "w1:p3",
          terminal_id: "term-3",
          workspace_id: "w1",
          tab_id: "w1:t1",
          focused: false,
          agent_status: "idle",
          revision: 1,
          tokens: { t3_thread_id: "thread-many", t3_terminal_index: "1" },
        },
        {
          pane_id: "w1:p4",
          terminal_id: "term-4",
          workspace_id: "w1",
          tab_id: "w1:t1",
          focused: false,
          agent_status: "idle",
          revision: 1,
          tokens: { t3_thread_id: "thread-many", t3_terminal_index: "2" },
        },
      ]),
    );

    const focused = await host.cycleThreadTerminal(input, 1);

    expect(focused).toEqual({
      paneId: "w1:p4",
      index: 2,
      total: 2,
      created: false,
    });
    expect(protocol.calls.at(-1)).toEqual({ method: "pane.focus", value: "w1:p4" });
    host.dispose();
  });
});

test("herdrWorkspaceCwd prefers worktree provenance then the active pane", () => {
  const fromPane = snapshot([
    {
      pane_id: "w1:p1",
      terminal_id: "term-1",
      workspace_id: "w1",
      tab_id: "w1:t1",
      focused: true,
      agent_status: "unknown",
      revision: 0,
      cwd: "/repo",
      foreground_cwd: "/repo/apps/web",
    },
  ]);
  expect(herdrWorkspaceCwd(fromPane, "w1")).toBe("/repo/apps/web");

  const fromWorktree = snapshot(fromPane.panes, {
    workspaces: [
      {
        ...fromPane.workspaces[0]!,
        worktree: {
          repo_key: "repo",
          repo_name: "repo",
          repo_root: "/repo",
          checkout_path: "/repo/worktree",
          is_linked_worktree: true,
        },
      },
    ],
  });
  expect(herdrWorkspaceCwd(fromWorktree, "w1")).toBe("/repo/worktree");
});
