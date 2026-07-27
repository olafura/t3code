import * as NodeFSP from "node:fs/promises";
import * as NodePath from "node:path";

import {
  HerdrProtocolClient,
  type HerdrAgentInfo,
  type HerdrPaneReadResult,
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
  readonly pluginId?: string;
  readonly stateDirectory?: string;
  readonly environmentKey: string;
  readonly reconnectBaseMs?: number;
  readonly reconnectMaxMs?: number;
}

interface PersistedLinks {
  readonly version: 1;
  readonly terminals: Readonly<Record<string, string>>;
}

const EMPTY_LINKS: PersistedLinks = { version: 1, terminals: {} };

export interface OpenThreadTerminalInput {
  readonly threadId: string;
  readonly title: string;
  readonly cwd: string;
}

export interface HerdrTuiHost {
  readonly kind: "herdr";
  readonly getState: () => HerdrHostState;
  readonly subscribe: (listener: () => void) => () => void;
  readonly start: () => void;
  readonly dispose: () => void;
  readonly readAgent: (target: string, lines?: number) => Promise<HerdrPaneReadResult>;
  readonly promptAgent: (target: string, text: string) => Promise<HerdrAgentInfo>;
  readonly focusAgent: (target: string) => Promise<void>;
  readonly interruptAgent: (target: string) => Promise<void>;
  readonly openThreadTerminal: (input: OpenThreadTerminalInput) => Promise<void>;
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

async function loadLinks(filePath: string | null): Promise<PersistedLinks> {
  if (!filePath) return EMPTY_LINKS;
  try {
    const parsed = JSON.parse(await NodeFSP.readFile(filePath, "utf8")) as Partial<PersistedLinks>;
    if (parsed.version !== 1 || typeof parsed.terminals !== "object" || !parsed.terminals) {
      return EMPTY_LINKS;
    }
    return { version: 1, terminals: parsed.terminals };
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
        await client.connect();
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
    openThreadTerminal: async (input) => {
      const snapshot = state.snapshot ?? (await client.snapshot());
      const links = await linksPromise;
      const linkKey = terminalLinkKey(options.environmentKey, input.threadId);
      const terminalId = links.terminals[linkKey];
      const linkedPane =
        snapshot.panes.find((pane) => pane.terminal_id === terminalId) ??
        snapshot.panes.find((pane) => pane.tokens?.t3_thread_id === input.threadId);
      if (linkedPane) {
        await client.focusPane(linkedPane.pane_id);
        return;
      }

      const pane = await client.splitPane({
        targetPaneId: options.paneId,
        workspaceId: options.workspaceId,
        cwd: input.cwd,
      });
      await client.reportPaneMetadata(
        pane.pane_id,
        {
          t3_thread_id: input.threadId,
          t3_environment: options.environmentKey.slice(0, 80),
        },
        `T3 · ${input.title}`,
      );
      const nextLinks: PersistedLinks = {
        version: 1,
        terminals: { ...links.terminals, [linkKey]: pane.terminal_id },
      };
      linksPromise = Promise.resolve(nextLinks);
      await writeLinks(linksPath, nextLinks);
      await refreshSnapshot();
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
