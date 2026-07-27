import * as NodeFSP from "node:fs/promises";
import * as NodePath from "node:path";

import {
  HerdrProtocolClient,
  type HerdrAgentInfo,
  type HerdrPaneReadResult,
  type HerdrReportedAgentState,
  type HerdrSessionSnapshot,
} from "./protocol.ts";

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
  readonly openThreadTerminal: (
    input: OpenThreadTerminalInput,
  ) => Promise<HerdrThreadTerminalResult>;
  readonly syncThreadTerminals: (
    threadId: string,
    inputs: ReadonlyArray<OpenThreadTerminalInput>,
  ) => Promise<void>;
  readonly closeThreadTerminal: (input: OpenThreadTerminalInput) => Promise<void>;
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
  readonly socketUrl: string;
  readonly origin: string;
  readonly threadId: string;
  readonly terminalId: string;
  readonly cwd: string;
  readonly worktreePath: string | null;
  readonly logPath: string;
}): string {
  return [
    input.executable,
    input.entry,
    "--herdr-terminal-bridge",
    "--socket-url",
    input.socketUrl,
    "--origin",
    input.origin,
    "--thread-id",
    input.threadId,
    "--terminal-id",
    input.terminalId,
    "--cwd",
    input.cwd,
    "--worktree-path",
    input.worktreePath ?? "-",
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
  let started = false;
  let disposed = false;
  let reconnectTimer: ReturnType<typeof setTimeout> | null = null;
  let reconnectAttempt = 0;
  let refreshTimer: ReturnType<typeof setTimeout> | null = null;
  let syncing: Promise<void> | null = null;
  let terminalOperations: Promise<void> = Promise.resolve();
  let threadReported = false;
  const agentName = "t3-code";
  const pluginSource = `plugin:${options.pluginId ?? "dev.t3code"}`;

  const threadTerminalPanes = (snapshot: HerdrSessionSnapshot, input: OpenThreadTerminalInput) =>
    snapshot.panes.filter(
      (pane) =>
        pane.pane_id !== options.paneId &&
        pane.tokens?.t3_thread_id === input.threadId &&
        pane.tokens.t3_terminal_id === input.terminalId,
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

  const runTerminalOperation = <A>(operation: () => Promise<A>): Promise<A> => {
    const result = terminalOperations.then(operation, operation);
    terminalOperations = result.then(
      () => undefined,
      () => undefined,
    );
    return result;
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
      disposed = true;
      started = false;
      if (reconnectTimer) clearTimeout(reconnectTimer);
      if (refreshTimer) clearTimeout(refreshTimer);
      reconnectTimer = null;
      refreshTimer = null;
      listeners.clear();
      client.dispose();
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
        displayAgent: "T3 Code",
        tokens: {
          t3_thread_id: input.threadId,
          t3_environment: options.environmentKey.slice(0, 80),
        },
      });
      threadReported = true;
    },
    openThreadTerminal: (input) =>
      runTerminalOperation(async () => {
        const snapshot = await client.snapshot();
        const linkedPane = threadTerminalPanes(snapshot, input)[0];
        if (linkedPane) {
          await client.focusAgent(linkedPane.pane_id);
          return {
            paneId: linkedPane.pane_id,
            index: input.index,
            total: input.total,
            created: false,
          };
        }
        return createThreadTerminal(input, true);
      }),
    syncThreadTerminals: (threadId, inputs) =>
      runTerminalOperation(async () => {
        const desiredTerminalIds = new Set(inputs.map((input) => input.terminalId));
        const initialSnapshot = await client.snapshot();
        const obsoletePanes = initialSnapshot.panes.filter(
          (pane) =>
            pane.tokens?.t3_environment === options.environmentKey.slice(0, 80) &&
            pane.tokens.t3_terminal_id !== undefined &&
            (pane.tokens.t3_thread_id !== threadId ||
              !desiredTerminalIds.has(pane.tokens.t3_terminal_id)),
        );
        for (const pane of obsoletePanes) await client.closePane(pane.pane_id);
        for (const input of inputs) {
          const snapshot = await client.snapshot();
          if (threadTerminalPanes(snapshot, input).length === 0) {
            await createThreadTerminal(input, false);
          }
        }
      }),
    closeThreadTerminal: (input) =>
      runTerminalOperation(async () => {
        const snapshot = await client.snapshot();
        const pane = threadTerminalPanes(snapshot, input)[0];
        if (pane) await client.closePane(pane.pane_id);
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

  async function createThreadTerminal(
    input: OpenThreadTerminalInput,
    focus: boolean,
  ): Promise<HerdrThreadTerminalResult> {
    if (!options.mintSocketUrl || !options.terminalBridgeEntry) {
      throw new Error("The T3 terminal bridge is unavailable in this Herdr pane.");
    }
    const cwd = await terminalCwd(input, options.isDirectory ?? isDirectory);
    const socketUrl = await options.mintSocketUrl();
    const terminalTitle = `Terminal ${input.index} · ${input.title}`;
    const pane = await client.createTab({
      workspaceId: options.workspaceId,
      cwd,
      label: terminalTitle,
      focus,
    });
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
        t3_environment: options.environmentKey.slice(0, 80),
        t3_terminal_id: input.terminalId.slice(0, 80),
        t3_terminal_index: String(input.index),
      },
      title: terminalTitle,
      displayAgent: "T3 Terminal",
    });
    const command = herdrTerminalBridgeCommand({
      executable: process.execPath,
      entry: options.terminalBridgeEntry,
      socketUrl,
      origin: options.environmentKey,
      threadId: input.threadId,
      terminalId: input.terminalId,
      cwd,
      worktreePath: input.worktreePath ?? null,
      logPath: options.stateDirectory
        ? NodePath.join(options.stateDirectory, `terminal-${input.terminalId}.log`)
        : "/tmp/t3-herdr-terminal.log",
    });
    await client.sendPaneInput(pane.pane_id, command, ["enter"]);
    await refreshSnapshot();
    return {
      paneId: pane.pane_id,
      index: input.index,
      total: input.total,
      created: true,
    };
  }
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
