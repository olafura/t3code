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
  readonly reconnectBaseMs?: number;
  readonly reconnectMaxMs?: number;
  readonly isDirectory?: (path: string) => Promise<boolean>;
}

interface PersistedLinks {
  readonly version: 2;
  readonly terminals: Readonly<Record<string, ReadonlyArray<string>>>;
}

const EMPTY_LINKS: PersistedLinks = { version: 2, terminals: {} };

export interface OpenThreadTerminalInput {
  readonly threadId: string;
  readonly title: string;
  readonly cwd: string;
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
  readonly createThreadTerminal: (
    input: OpenThreadTerminalInput,
  ) => Promise<HerdrThreadTerminalResult>;
  readonly cycleThreadTerminal: (
    input: OpenThreadTerminalInput,
    delta: 1 | -1,
  ) => Promise<HerdrThreadTerminalResult>;
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

function terminalLinkKey(environmentKey: string, threadId: string): string {
  return `${environmentKey}\u0000${threadId}`;
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

async function loadLinks(filePath: string | null): Promise<PersistedLinks> {
  if (!filePath) return EMPTY_LINKS;
  try {
    const parsed = JSON.parse(await NodeFSP.readFile(filePath, "utf8")) as {
      readonly version?: unknown;
      readonly terminals?: unknown;
    };
    if (typeof parsed.terminals !== "object" || !parsed.terminals) {
      return EMPTY_LINKS;
    }
    const terminals = Object.fromEntries(
      Object.entries(parsed.terminals).flatMap(([key, value]) => {
        if (typeof value === "string") return [[key, [value]]];
        if (Array.isArray(value) && value.every((item) => typeof item === "string")) {
          return [[key, value]];
        }
        return [];
      }),
    );
    return { version: 2, terminals };
  } catch {
    return EMPTY_LINKS;
  }
}

async function writeLinks(filePath: string | null, links: PersistedLinks): Promise<void> {
  if (!filePath) return;
  await NodeFSP.mkdir(NodePath.dirname(filePath), { recursive: true });
  const temporary = `${filePath}.${process.pid}.tmp`;
  await NodeFSP.writeFile(temporary, `${JSON.stringify(links, null, 2)}\n`, "utf8");
  await NodeFSP.rename(temporary, filePath);
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
  const linksPath = options.stateDirectory
    ? NodePath.join(options.stateDirectory, "links-v1.json")
    : null;
  let linksPromise = loadLinks(linksPath);
  let started = false;
  let disposed = false;
  let reconnectTimer: ReturnType<typeof setTimeout> | null = null;
  let reconnectAttempt = 0;
  let refreshTimer: ReturnType<typeof setTimeout> | null = null;
  let syncing: Promise<void> | null = null;
  let threadReported = false;
  const lastFocusedTerminal = new Map<string, string>();
  const agentName = "t3-code";
  const pluginSource = `plugin:${options.pluginId ?? "dev.t3code"}`;

  const threadTerminalPanes = (
    snapshot: HerdrSessionSnapshot,
    links: PersistedLinks,
    input: OpenThreadTerminalInput,
  ) => {
    const linkKey = terminalLinkKey(options.environmentKey, input.threadId);
    const linkedIds = new Set(links.terminals[linkKey] ?? []);
    return snapshot.panes.filter(
      (pane) =>
        pane.pane_id !== options.paneId &&
        (linkedIds.has(pane.terminal_id) ||
          (pane.tokens?.t3_thread_id === input.threadId &&
            pane.tokens.t3_terminal_index !== undefined)),
    );
  };

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
    openThreadTerminal: async (input) => {
      const snapshot = await client.snapshot();
      const links = await linksPromise;
      const terminals = threadTerminalPanes(snapshot, links, input);
      const linkedPane = terminals[0];
      if (linkedPane) {
        await client.focusPane(linkedPane.pane_id);
        lastFocusedTerminal.set(input.threadId, linkedPane.pane_id);
        return {
          paneId: linkedPane.pane_id,
          index: 1,
          total: terminals.length,
          created: false,
        };
      }

      return createThreadTerminal(input);
    },
    createThreadTerminal: async (input) => createThreadTerminal(input),
    cycleThreadTerminal: async (input, delta) => {
      const snapshot = await client.snapshot();
      const links = await linksPromise;
      const terminals = threadTerminalPanes(snapshot, links, input);
      if (terminals.length === 0) {
        throw new Error("This thread has no Herdr terminal instances.");
      }
      const focusedPaneId =
        terminals.find((pane) => pane.pane_id === snapshot.focused_pane_id)?.pane_id ??
        lastFocusedTerminal.get(input.threadId);
      const focusedIndex = terminals.findIndex((pane) => pane.pane_id === focusedPaneId);
      const nextIndex =
        focusedIndex < 0
          ? delta > 0
            ? 0
            : terminals.length - 1
          : (focusedIndex + delta + terminals.length) % terminals.length;
      const terminal = terminals[nextIndex]!;
      await client.focusPane(terminal.pane_id);
      lastFocusedTerminal.set(input.threadId, terminal.pane_id);
      return {
        paneId: terminal.pane_id,
        index: nextIndex + 1,
        total: terminals.length,
        created: false,
      };
    },
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
  ): Promise<HerdrThreadTerminalResult> {
    const snapshot = await client.snapshot();
    const links = await linksPromise;
    const existing = threadTerminalPanes(snapshot, links, input);
    const cwd = await terminalCwd(input, options.isDirectory ?? isDirectory);
    const pane = await client.splitPane({
      targetPaneId: options.paneId,
      workspaceId: options.workspaceId,
      cwd,
      direction: "down",
      ratio: 0.62,
    });
    const index = existing.length + 1;
    const terminalTitle = `Terminal ${index} · ${input.title}`;
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
        t3_terminal_index: String(index),
      },
      title: terminalTitle,
      displayAgent: "T3 Terminal",
    });
    const linkKey = terminalLinkKey(options.environmentKey, input.threadId);
    const nextLinks: PersistedLinks = {
      version: 2,
      terminals: {
        ...links.terminals,
        [linkKey]: [...(links.terminals[linkKey] ?? []), pane.terminal_id],
      },
    };
    linksPromise = Promise.resolve(nextLinks);
    lastFocusedTerminal.set(input.threadId, pane.pane_id);
    await writeLinks(linksPath, nextLinks);
    await refreshSnapshot();
    return { paneId: pane.pane_id, index, total: index, created: true };
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
