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
  readonly environmentKey: string;
  readonly reconnectBaseMs?: number;
  readonly reconnectMaxMs?: number;
}

export interface ReportThreadAgentInput {
  readonly threadId: string;
  readonly title: string;
  readonly state: HerdrReportedAgentState;
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
  let threadReported = false;
  const agentName = "t3-code";
  const pluginSource = `plugin:${options.pluginId ?? "dev.t3code"}`;

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
