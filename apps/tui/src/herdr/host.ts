import * as NodeFSP from "node:fs/promises";
import * as NodePath from "node:path";

import {
  HerdrProtocolClient,
  type HerdrAgentInfo,
  type HerdrAgentViewItem,
  type HerdrPaneReadResult,
  type HerdrReportedAgentState,
  type HerdrSessionSnapshot,
  HERDR_SIDEBAR_PROTOCOL,
} from "./protocol.ts";
import { decodeHerdrSidebarAction, type HerdrSidebarAction } from "./sidebar.ts";
import {
  encodeHerdrTerminalSwitch,
  type HerdrTerminalLaunchTarget,
  type HerdrTerminalTarget,
} from "./terminalBridge.ts";

export type HerdrConnectionState = "connecting" | "connected" | "disconnected" | "error";

export interface HerdrHostState {
  readonly connection: HerdrConnectionState;
  readonly snapshot: HerdrSessionSnapshot | null;
  readonly error: string | null;
}

export interface HerdrHostOptions {
  readonly socketPath: string;
  readonly paneId: string;
  readonly workspaceId: string;
  readonly workspaceCwd?: string;
  readonly pluginId?: string;
  readonly stateDirectory?: string;
  readonly environmentKey: string;
  readonly mintSocketUrl?: () => Promise<string>;
  readonly terminalBridgeEntry?: string;
  readonly reconnectBaseMs?: number;
  readonly reconnectMaxMs?: number;
  readonly isDirectory?: (path: string) => Promise<boolean>;
}

export interface OpenThreadTerminalInput {
  readonly threadId: string;
  readonly terminalId: string;
  readonly index: number;
  readonly total: number;
  readonly title: string;
  readonly cwd: string;
  readonly worktreePath?: string | null;
  readonly fallbackCwd?: string;
}

export interface ReportThreadAgentInput {
  readonly threadId: string;
  readonly title: string;
  readonly state: HerdrReportedAgentState;
  readonly project?: string;
  readonly branch?: string | null;
  readonly model?: string | null;
}

export interface HerdrThreadTerminalResult {
  readonly paneId: string;
  readonly index: number;
  readonly total: number;
  readonly created: boolean;
}

export interface HerdrTuiHost {
  readonly kind: "herdr";
  readonly workspaceId: string;
  readonly workspaceCwd: string;
  readonly getState: () => HerdrHostState;
  readonly subscribe: (listener: () => void) => () => void;
  readonly start: () => void;
  readonly dispose: () => void;
  readonly readAgent: (target: string, lines?: number) => Promise<HerdrPaneReadResult>;
  readonly promptAgent: (target: string, text: string) => Promise<HerdrAgentInfo>;
  readonly focusAgent: (target: string) => Promise<void>;
  readonly interruptAgent: (target: string) => Promise<void>;
  readonly reportThread: (input: ReportThreadAgentInput | null) => Promise<void>;
  readonly reportSidebar: (
    items: ReadonlyArray<Omit<HerdrAgentViewItem, "targetPaneId">>,
  ) => Promise<boolean>;
  readonly subscribeSidebarActions: (listener: (action: HerdrSidebarAction) => void) => () => void;
  readonly handleInput: (input: string) => boolean;
  readonly openThreadTerminal: (
    input: OpenThreadTerminalInput,
  ) => Promise<HerdrThreadTerminalResult>;
  readonly focusThreadTerminalPane: () => Promise<boolean>;
  readonly closeThreadTerminalPane: () => Promise<void>;
  readonly openServerPane: () => Promise<void>;
}

export interface StandaloneTuiHost {
  readonly kind: "standalone";
}

export type TuiHost = StandaloneTuiHost | HerdrTuiHost;

export const standaloneTuiHost: StandaloneTuiHost = { kind: "standalone" };

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

async function isDirectory(path: string): Promise<boolean> {
  try {
    return (await NodeFSP.stat(path)).isDirectory();
  } catch {
    return false;
  }
}

async function terminalCwd(
  input: OpenThreadTerminalInput,
  checkDirectory: (path: string) => Promise<boolean>,
): Promise<string> {
  if (!input.fallbackCwd || input.fallbackCwd === input.cwd) return input.cwd;
  if (await checkDirectory(input.cwd)) return input.cwd;
  if (await checkDirectory(input.fallbackCwd)) return input.fallbackCwd;
  throw new Error("Neither the thread worktree nor its project directory exists.");
}

function shellQuote(value: string): string {
  return `'${value.replaceAll("'", "'\\''")}'`;
}

export function herdrTerminalBridgeCommand(input: {
  readonly executable: string;
  readonly entry: string;
  readonly target: HerdrTerminalLaunchTarget;
  readonly herdrSocketPath: string;
  readonly dashboardPaneId: string;
  readonly terminalPaneId: string;
  readonly logPath: string;
}): string {
  return [
    input.executable,
    input.entry,
    "--herdr-terminal-bridge",
    "--socket-url",
    input.target.socketUrl,
    "--origin",
    input.target.origin,
    "--thread-id",
    input.target.threadId,
    "--terminal-id",
    input.target.terminalId,
    "--cwd",
    input.target.cwd,
    "--worktree-path",
    input.target.worktreePath ?? "-",
    "--herdr-socket-path",
    input.herdrSocketPath,
    "--dashboard-pane-id",
    input.dashboardPaneId,
    "--terminal-pane-id",
    input.terminalPaneId,
    "--log-path",
    input.logPath,
  ]
    .map(shellQuote)
    .join(" ");
}

export function createHerdrTuiHost(
  options: HerdrHostOptions,
  client = new HerdrProtocolClient(options.socketPath),
): HerdrTuiHost {
  let state: HerdrHostState = {
    connection: "disconnected",
    snapshot: null,
    error: null,
  };
  const listeners = new Set<() => void>();
  const sidebarActionListeners = new Set<(action: HerdrSidebarAction) => void>();
  let started = false;
  let disposed = false;
  let reconnectTimer: ReturnType<typeof setTimeout> | null = null;
  let reconnectAttempt = 0;
  let refreshTimer: ReturnType<typeof setTimeout> | null = null;
  let syncing: Promise<void> | null = null;
  let terminalOperations: Promise<void> = Promise.resolve();
  let sidebarOperations: Promise<void> = Promise.resolve();
  let sidebarRequest: {
    readonly fingerprint: string;
    readonly result: Promise<boolean>;
  } | null = null;
  let threadReported = false;
  const agentName = "t3-code";
  const pluginSource = `plugin:${options.pluginId ?? "dev.t3code"}`;
  const environmentToken = options.environmentKey.slice(0, 80);

  const terminalBridgePane = (snapshot: HerdrSessionSnapshot) =>
    snapshot.panes.find(
      (pane) =>
        pane.pane_id !== options.paneId &&
        pane.tokens?.t3_environment === environmentToken &&
        pane.tokens.t3_terminal_bridge === "1",
    );

  const emit = () => {
    for (const listener of listeners) listener();
  };
  const setState = (patch: Partial<HerdrHostState>) => {
    state = { ...state, ...patch };
    emit();
  };

  const refreshSnapshot = async () => {
    const snapshot = await client.snapshot();
    setState({ connection: "connected", snapshot, error: null });
  };

  const scheduleReconnect = () => {
    if (disposed || !started || reconnectTimer) return;
    const base = options.reconnectBaseMs ?? 250;
    const maximum = options.reconnectMaxMs ?? 5_000;
    const delay = Math.min(maximum, base * 2 ** reconnectAttempt);
    reconnectAttempt += 1;
    reconnectTimer = setTimeout(() => {
      reconnectTimer = null;
      void sync();
    }, delay);
    reconnectTimer.unref?.();
  };

  const scheduleRefresh = () => {
    if (disposed || refreshTimer) return;
    refreshTimer = setTimeout(() => {
      refreshTimer = null;
      void refreshSnapshot().catch((error) => {
        setState({ connection: "error", error: errorMessage(error) });
        scheduleReconnect();
      });
    }, 25);
    refreshTimer.unref?.();
  };

  const runTerminalOperation = <A>(operation: () => Promise<A>): Promise<A> => {
    const result = terminalOperations.then(operation, operation);
    terminalOperations = result.then(
      () => undefined,
      () => undefined,
    );
    return result;
  };

  const sync = async (): Promise<void> => {
    if (disposed || syncing) return syncing ?? Promise.resolve();
    setState({ connection: "connecting", error: null });
    syncing = (async () => {
      try {
        await client.ping();
        await client.subscribeToLifecycleEvents();
        await refreshSnapshot();
        reconnectAttempt = 0;
      } catch (error) {
        setState({ connection: "error", error: errorMessage(error) });
        scheduleReconnect();
      } finally {
        syncing = null;
      }
    })();
    return syncing;
  };

  client.onEvent(() => scheduleRefresh());
  client.onDisconnect((error) => {
    if (disposed) return;
    setState({ connection: "disconnected", error: error.message });
    scheduleReconnect();
  });

  return {
    kind: "herdr",
    workspaceId: options.workspaceId,
    workspaceCwd: options.workspaceCwd ?? process.cwd(),
    getState: () => state,
    subscribe: (listener) => {
      listeners.add(listener);
      return () => listeners.delete(listener);
    },
    start: () => {
      if (started) return;
      started = true;
      void sync();
    },
    dispose: () => {
      if (disposed) return;
      disposed = true;
      started = false;
      if (reconnectTimer) clearTimeout(reconnectTimer);
      if (refreshTimer) clearTimeout(refreshTimer);
      reconnectTimer = null;
      refreshTimer = null;
      listeners.clear();
      sidebarActionListeners.clear();
      void client
        .clearAgentView(pluginSource)
        .catch(() => {})
        .finally(() => client.dispose());
    },
    readAgent: (target, lines) => client.readAgent(target, lines),
    promptAgent: (target, text) => client.promptAgent(target, text),
    focusAgent: (target) => client.focusAgent(target),
    interruptAgent: (target) => client.sendAgentKeys(target, ["ctrl+c"]),
    reportThread: async (input) => {
      if (!input) {
        if (!threadReported) return;
        await client.releasePaneAgent({
          paneId: options.paneId,
          source: pluginSource,
          agent: agentName,
        });
        threadReported = false;
        return;
      }
      await client.reportPaneAgent({
        paneId: options.paneId,
        source: pluginSource,
        agent: agentName,
        state: input.state,
        message: input.title,
        sessionId: input.threadId,
      });
      await client.reportPaneMetadata({
        paneId: options.paneId,
        source: pluginSource,
        title: input.title,
        displayAgent: input.title,
        tokens: {
          t3_thread_id: input.threadId,
          t3_environment: environmentToken,
          t3_project: input.project?.slice(0, 80) ?? null,
          t3_branch: input.branch?.slice(0, 80) ?? null,
          t3_model: input.model?.slice(0, 80) ?? null,
        },
      });
      threadReported = true;
    },
    reportSidebar: async (items) => {
      if ((state.snapshot?.protocol ?? 0) < HERDR_SIDEBAR_PROTOCOL) return false;
      const fingerprint = JSON.stringify(items);
      if (sidebarRequest?.fingerprint === fingerprint) return sidebarRequest.result;
      const operation = sidebarOperations.then(() =>
        client.setAgentView({
          source: pluginSource,
          label: "T3 Code",
          filter: {
            op: "not",
            filter: {
              op: "eq",
              field: { token: "t3_environment" },
              value: environmentToken,
            },
          },
          sort: [{ field: { token: "t3_order" }, order: "asc" }],
          items: items.map((item) => ({ ...item, targetPaneId: options.paneId })),
        }),
      );
      sidebarOperations = operation.catch(() => {});
      const result = operation.then(() => true);
      sidebarRequest = { fingerprint, result };
      void result.catch(() => {
        if (sidebarRequest?.fingerprint === fingerprint) sidebarRequest = null;
      });
      return result;
    },
    subscribeSidebarActions: (listener) => {
      sidebarActionListeners.add(listener);
      return () => sidebarActionListeners.delete(listener);
    },
    handleInput: (input) => {
      const action = decodeHerdrSidebarAction(input);
      if (!action) return false;
      for (const listener of sidebarActionListeners) listener(action);
      return true;
    },
    openThreadTerminal: (input) =>
      runTerminalOperation(async () => {
        if (!options.mintSocketUrl || !options.terminalBridgeEntry) {
          throw new Error("The T3 terminal bridge is unavailable in this Herdr pane.");
        }
        const cwd = await terminalCwd(input, options.isDirectory ?? isDirectory);
        const target: HerdrTerminalTarget = {
          origin: options.environmentKey,
          threadId: input.threadId,
          terminalId: input.terminalId,
          cwd,
          worktreePath: input.worktreePath ?? null,
        };
        const current = await client.snapshot();
        let pane = terminalBridgePane(current);
        const created = !pane;
        if (!pane) {
          pane = await client.splitPane({
            targetPaneId: options.paneId,
            workspaceId: options.workspaceId,
            cwd,
            direction: "down",
            ratio: 0.62,
          });
        }
        const terminalTitle = `Terminal ${input.index}/${input.total} · ${input.title}`;
        await client.reportPaneAgent({
          paneId: pane.pane_id,
          source: pluginSource,
          agent: "t3-terminal",
          state: "idle",
          message: terminalTitle,
        });
        await client.reportPaneMetadata({
          paneId: pane.pane_id,
          source: pluginSource,
          tokens: {
            t3_thread_id: input.threadId,
            t3_environment: environmentToken,
            t3_terminal_bridge: "1",
            t3_terminal_id: input.terminalId.slice(0, 80),
            t3_terminal_index: String(input.index),
          },
          title: terminalTitle,
          displayAgent: terminalTitle,
        });
        if (created) {
          const launchTarget: HerdrTerminalLaunchTarget = {
            ...target,
            socketUrl: await options.mintSocketUrl(),
          };
          const command = herdrTerminalBridgeCommand({
            executable: process.execPath,
            entry: options.terminalBridgeEntry,
            target: launchTarget,
            herdrSocketPath: options.socketPath,
            dashboardPaneId: options.paneId,
            terminalPaneId: pane.pane_id,
            logPath: options.stateDirectory
              ? NodePath.join(options.stateDirectory, "terminal-bridge.log")
              : "/tmp/t3-herdr-terminal.log",
          });
          await client.sendPaneInput(pane.pane_id, command, ["enter"]);
        } else {
          await client.sendPaneText(pane.pane_id, encodeHerdrTerminalSwitch(target));
          await client.focusPane(pane.pane_id);
        }
        await refreshSnapshot();
        return {
          paneId: pane.pane_id,
          index: input.index,
          total: input.total,
          created,
        };
      }),
    focusThreadTerminalPane: async () => {
      const pane = terminalBridgePane(await client.snapshot());
      if (!pane) return false;
      await client.focusPane(pane.pane_id);
      return true;
    },
    closeThreadTerminalPane: () =>
      runTerminalOperation(async () => {
        const pane = terminalBridgePane(await client.snapshot());
        if (!pane) return;
        await client.closePane(pane.pane_id);
        await refreshSnapshot();
      }),
    openServerPane: async () => {
      if (!options.pluginId) {
        throw new Error("The Herdr plugin id is unavailable.");
      }
      await client.openPluginPane({
        pluginId: options.pluginId,
        entrypoint: "server",
        workspaceId: options.workspaceId,
        placement: "tab",
      });
    },
  };
}

export function herdrWorkspaceCwd(
  snapshot: HerdrSessionSnapshot,
  workspaceId: string,
): string | null {
  const workspace = snapshot.workspaces.find((entry) => entry.workspace_id === workspaceId);
  if (!workspace) return null;
  if (workspace.worktree?.checkout_path) return workspace.worktree.checkout_path;
  const activeLayout = snapshot.layouts.find(
    (layout) => layout.workspace_id === workspaceId && layout.tab_id === workspace.active_tab_id,
  );
  const focusedPane = activeLayout
    ? snapshot.panes.find((pane) => pane.pane_id === activeLayout.focused_pane_id)
    : null;
  return (
    focusedPane?.foreground_cwd ??
    focusedPane?.cwd ??
    snapshot.panes.find((pane) => pane.workspace_id === workspaceId)?.cwd ??
    null
  );
}
