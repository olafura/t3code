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
    ping: async () => ({ version: current.version, protocol: current.protocol }),
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
    setAgentView: async (input: unknown) => {
      calls.push({ method: "agent.view.set", value: input });
    },
    clearAgentView: async (source: string) => {
      calls.push({ method: "agent.view.clear", value: source });
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
      const report = input as {
        readonly paneId: string;
        readonly tokens: Readonly<Record<string, string | null>>;
      };
      current = snapshot(
        current.panes.map((pane) =>
          pane.pane_id === report.paneId
            ? {
                ...pane,
                tokens: Object.fromEntries(
                  Object.entries({ ...pane.tokens, ...report.tokens }).filter(
                    (entry): entry is [string, string] => entry[1] !== null,
                  ),
                ),
              }
            : pane,
        ),
      );
    },
    sendPaneInput: async (paneId: string, text: string, keys: ReadonlyArray<string> = []) => {
      calls.push({ method: "pane.send_input", value: { paneId, text, keys } });
    },
    closePane: async (paneId: string) => {
      calls.push({ method: "pane.close", value: paneId });
      current = snapshot(current.panes.filter((pane) => pane.pane_id !== paneId));
    },
    openPluginPane: async (input: unknown) => {
      calls.push({ method: "plugin.pane.open", value: input });
    },
    dispose: () => {},
  };
}

const hostOptions = {
  socketPath: "/tmp/herdr.sock",
  paneId: "w1:p1",
  workspaceId: "w1",
  environmentKey: "http://127.0.0.1:5733",
} as const;

describe("createHerdrTuiHost", () => {
  test("reports the selected T3 thread through Herdr's native agent model", async () => {
    const protocol = fakeProtocol(snapshot());
    const host = createHerdrTuiHost(
      { ...hostOptions, pluginId: "dev.t3code", environmentKey: "local" },
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
          displayAgent: "Fix terminal integration",
          tokens: {
            t3_thread_id: "thread-1",
            t3_environment: "local",
            t3_project: null,
            t3_branch: null,
            t3_model: null,
          },
        },
      },
    ]);
    host.dispose();
  });

  test("publishes native sidebar items and dispatches their private actions", async () => {
    const protocol = fakeProtocol(snapshot([], { protocol: 19 }));
    const host = createHerdrTuiHost(
      { ...hostOptions, pluginId: "dev.t3code", environmentKey: "local" },
      protocol as never,
    );
    host.start();
    await Bun.sleep(5);
    const actions: unknown[] = [];
    host.subscribeSidebarActions((action) => actions.push(action));
    const activationInput = "\u001bP+t3-sidebar;eyJraW5kIjoidGhyZWFkIiwiaWQiOiJ0MSJ9\u001b\\";

    await expect(
      host.reportSidebar([
        {
          id: "thread:t1",
          label: "Fix sidebar",
          status: "working",
          seen: true,
          tokens: { project: "t3code", selected: "1", t3_order: "000002" },
          activationInput,
        },
      ]),
    ).resolves.toBe(true);
    expect(host.handleInput(activationInput)).toBe(true);
    expect(actions).toEqual([{ kind: "thread", id: "t1" }]);
    expect(protocol.calls).toContainEqual({
      method: "agent.view.set",
      value: {
        source: "plugin:dev.t3code",
        label: "T3 Code",
        filter: {
          op: "not",
          filter: {
            op: "eq",
            field: { token: "t3_environment" },
            value: "local",
          },
        },
        sort: [{ field: { token: "t3_order" }, order: "asc" }],
        items: [
          {
            id: "thread:t1",
            targetPaneId: "w1:p1",
            label: "Fix sidebar",
            status: "working",
            seen: true,
            tokens: { project: "t3code", selected: "1", t3_order: "000002" },
            activationInput,
          },
        ],
      },
    });
    host.dispose();
  });

  test("keeps one native bottom pane and retargets it between T3 terminal tabs", async () => {
    const protocol = fakeProtocol(snapshot());
    let ticket = 0;
    const host = createHerdrTuiHost(
      {
        ...hostOptions,
        pluginId: "dev.t3code",
        terminalBridgeEntry: "/checkout/apps/tui/src/index.tsx",
        mintSocketUrl: async () => `ws://127.0.0.1/ws?ticket=${++ticket}`,
        isDirectory: async () => true,
      },
      protocol as never,
    );

    await host.openThreadTerminal({
      threadId: "thread-1",
      terminalId: "term-1",
      index: 1,
      total: 2,
      title: "Fix terminal integration",
      cwd: "/repo/worktree",
      worktreePath: "/repo/worktree",
    });
    await host.openThreadTerminal({
      threadId: "thread-1",
      terminalId: "term-2",
      index: 2,
      total: 2,
      title: "Fix terminal integration",
      cwd: "/repo/worktree",
      worktreePath: "/repo/worktree",
    });

    expect(protocol.calls.filter((call) => call.method === "pane.split")).toEqual([
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
    ]);
    const sends = protocol.calls.filter((call) => call.method === "pane.send_input");
    expect(sends).toHaveLength(2);
    expect(JSON.stringify(sends[0]?.value)).toContain("--herdr-terminal-bridge");
    expect(JSON.stringify(sends[0]?.value)).toContain("--terminal-pane-id");
    expect(JSON.stringify(sends[1]?.value)).toContain("\\u001bP+t3-terminal;");
    expect(protocol.calls).toContainEqual({ method: "pane.focus", value: "w1:p3" });
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
