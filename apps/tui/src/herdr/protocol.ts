import * as NodeNet from "node:net";

export const HERDR_MIN_PROTOCOL = 17;

export type HerdrAgentStatus = "idle" | "working" | "blocked" | "done" | "unknown";

export interface HerdrWorktreeInfo {
  readonly repo_key: string;
  readonly repo_name: string;
  readonly repo_root: string;
  readonly checkout_path: string;
  readonly is_linked_worktree: boolean;
}

export interface HerdrWorkspaceInfo {
  readonly workspace_id: string;
  readonly number: number;
  readonly label: string;
  readonly focused: boolean;
  readonly pane_count: number;
  readonly tab_count: number;
  readonly active_tab_id: string;
  readonly agent_status: HerdrAgentStatus;
  readonly worktree?: HerdrWorktreeInfo | null;
  readonly tokens?: Readonly<Record<string, string>>;
}

export interface HerdrTabInfo {
  readonly tab_id: string;
  readonly workspace_id: string;
  readonly number: number;
  readonly label: string;
  readonly focused: boolean;
  readonly pane_count: number;
  readonly agent_status: HerdrAgentStatus;
}

export interface HerdrAgentSession {
  readonly source: string;
  readonly agent: string;
  readonly kind: "id" | "path";
  readonly value: string;
}

export interface HerdrPaneInfo {
  readonly pane_id: string;
  readonly terminal_id: string;
  readonly workspace_id: string;
  readonly tab_id: string;
  readonly focused: boolean;
  readonly agent_status: HerdrAgentStatus;
  readonly revision: number;
  readonly cwd?: string | null;
  readonly foreground_cwd?: string | null;
  readonly agent?: string | null;
  readonly display_agent?: string | null;
  readonly title?: string | null;
  readonly terminal_title?: string | null;
  readonly terminal_title_stripped?: string | null;
  readonly agent_session?: HerdrAgentSession | null;
  readonly tokens?: Readonly<Record<string, string>>;
}

export interface HerdrAgentInfo extends HerdrPaneInfo {
  readonly interactive_ready?: boolean;
  readonly launch_pending?: boolean;
  readonly name?: string | null;
  readonly state_change_seq?: number;
}

export interface HerdrLayoutSnapshot {
  readonly workspace_id: string;
  readonly tab_id: string;
  readonly focused_pane_id: string;
  readonly zoomed: boolean;
}

export interface HerdrSessionSnapshot {
  readonly version: string;
  readonly protocol: number;
  readonly focused_workspace_id?: string | null;
  readonly focused_tab_id?: string | null;
  readonly focused_pane_id?: string | null;
  readonly workspaces: ReadonlyArray<HerdrWorkspaceInfo>;
  readonly tabs: ReadonlyArray<HerdrTabInfo>;
  readonly panes: ReadonlyArray<HerdrPaneInfo>;
  readonly layouts: ReadonlyArray<HerdrLayoutSnapshot>;
  readonly agents: ReadonlyArray<HerdrAgentInfo>;
}

export interface HerdrPaneReadResult {
  readonly pane_id: string;
  readonly workspace_id: string;
  readonly tab_id: string;
  readonly source: string;
  readonly format: string;
  readonly text: string;
  readonly revision: number;
  readonly truncated: boolean;
}

export interface HerdrEventEnvelope {
  readonly event: string;
  readonly data: Readonly<Record<string, unknown>>;
}

interface HerdrSuccessEnvelope {
  readonly id: string;
  readonly result: Readonly<Record<string, unknown>>;
}

interface HerdrErrorEnvelope {
  readonly id: string;
  readonly error: {
    readonly code: string;
    readonly message: string;
  };
}

type HerdrEnvelope = HerdrSuccessEnvelope | HerdrErrorEnvelope | HerdrEventEnvelope;

export class HerdrRpcError extends Error {
  readonly code: string;

  constructor(code: string, message: string) {
    super(message);
    this.name = "HerdrRpcError";
    this.code = code;
  }
}

export class HerdrProtocolVersionError extends Error {
  readonly actual: number;

  constructor(actual: number) {
    super(`Herdr protocol ${actual} is older than required protocol ${HERDR_MIN_PROTOCOL}.`);
    this.name = "HerdrProtocolVersionError";
    this.actual = actual;
  }
}

type PendingRequest = {
  readonly resolve: (result: Readonly<Record<string, unknown>>) => void;
  readonly reject: (error: Error) => void;
};

type SocketFactory = (path: string) => NodeNet.Socket;

const DEFAULT_EVENT_SUBSCRIPTIONS = [
  "workspace.created",
  "workspace.updated",
  "workspace.metadata_updated",
  "workspace.renamed",
  "workspace.moved",
  "workspace.closed",
  "workspace.focused",
  "worktree.created",
  "worktree.opened",
  "worktree.removed",
  "tab.created",
  "tab.closed",
  "tab.focused",
  "tab.renamed",
  "tab.moved",
  "pane.created",
  "pane.updated",
  "pane.closed",
  "pane.focused",
  "pane.moved",
  "pane.exited",
  "pane.agent_detected",
  "pane.agent_status_changed",
  "layout.updated",
] as const;

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}

function decodeEnvelope(line: string): HerdrEnvelope | null {
  let parsed: unknown;
  try {
    parsed = JSON.parse(line);
  } catch {
    return null;
  }
  if (!isRecord(parsed)) return null;
  if (typeof parsed.id === "string") {
    if (isRecord(parsed.error)) {
      return {
        id: parsed.id,
        error: {
          code: typeof parsed.error.code === "string" ? parsed.error.code : "unknown",
          message:
            typeof parsed.error.message === "string" ? parsed.error.message : "Unknown Herdr error",
        },
      };
    }
    if (isRecord(parsed.result)) {
      return { id: parsed.id, result: parsed.result };
    }
    return null;
  }
  if (typeof parsed.event === "string" && isRecord(parsed.data)) {
    return { event: parsed.event, data: parsed.data };
  }
  return null;
}

function readTypedResult<T>(
  result: Readonly<Record<string, unknown>>,
  key: string,
  description: string,
): T {
  const value = result[key];
  if (value === undefined) {
    throw new Error(`Herdr returned no ${description}.`);
  }
  return value as T;
}

export class HerdrProtocolClient {
  readonly socketPath: string;

  private readonly socketFactory: SocketFactory;
  private socket: NodeNet.Socket | null = null;
  private connecting: Promise<void> | null = null;
  private buffer = "";
  private nextRequestId = 1;
  private readonly pending = new Map<string, PendingRequest>();
  private readonly eventListeners = new Set<(event: HerdrEventEnvelope) => void>();
  private readonly disconnectListeners = new Set<(error: Error) => void>();

  constructor(socketPath: string, socketFactory: SocketFactory = NodeNet.createConnection) {
    this.socketPath = socketPath;
    this.socketFactory = socketFactory;
  }

  connect(): Promise<void> {
    if (this.socket && !this.socket.destroyed) return Promise.resolve();
    if (this.connecting) return this.connecting;

    this.connecting = new Promise<void>((resolve, reject) => {
      let settled = false;
      const socket = this.socketFactory(this.socketPath);
      this.socket = socket;
      socket.setEncoding("utf8");
      socket.on("data", (chunk: string) => this.handleData(chunk));
      socket.once("connect", () => {
        settled = true;
        resolve();
      });
      socket.once("error", (cause) => {
        const error = cause instanceof Error ? cause : new Error(String(cause));
        if (!settled) reject(error);
      });
      socket.once("close", () => {
        const error = new Error("Herdr socket disconnected.");
        if (!settled) reject(error);
        if (this.socket === socket) this.socket = null;
        this.buffer = "";
        for (const pending of this.pending.values()) pending.reject(error);
        this.pending.clear();
        for (const listener of this.disconnectListeners) listener(error);
      });
    }).finally(() => {
      this.connecting = null;
    });
    return this.connecting;
  }

  onEvent(listener: (event: HerdrEventEnvelope) => void): () => void {
    this.eventListeners.add(listener);
    return () => this.eventListeners.delete(listener);
  }

  onDisconnect(listener: (error: Error) => void): () => void {
    this.disconnectListeners.add(listener);
    return () => this.disconnectListeners.delete(listener);
  }

  async request(
    method: string,
    params: Readonly<Record<string, unknown>> = {},
  ): Promise<Readonly<Record<string, unknown>>> {
    await this.connect();
    const socket = this.socket;
    if (!socket || socket.destroyed) throw new Error("Herdr socket is unavailable.");
    const id = `t3_${this.nextRequestId++}`;
    const response = new Promise<Readonly<Record<string, unknown>>>((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
    });
    socket.write(`${JSON.stringify({ id, method, params })}\n`, (error) => {
      if (!error) return;
      const pending = this.pending.get(id);
      this.pending.delete(id);
      pending?.reject(error);
    });
    return response;
  }

  async ping(): Promise<{ readonly version: string; readonly protocol: number }> {
    const result = await this.request("ping");
    const protocol = readTypedResult<number>(result, "protocol", "protocol version");
    if (protocol < HERDR_MIN_PROTOCOL) throw new HerdrProtocolVersionError(protocol);
    return {
      version: readTypedResult<string>(result, "version", "server version"),
      protocol,
    };
  }

  async snapshot(): Promise<HerdrSessionSnapshot> {
    const result = await this.request("session.snapshot");
    return readTypedResult<HerdrSessionSnapshot>(result, "snapshot", "session snapshot");
  }

  async subscribeToLifecycleEvents(): Promise<void> {
    await this.request("events.subscribe", {
      subscriptions: DEFAULT_EVENT_SUBSCRIPTIONS.map((type) => ({ type })),
    });
  }

  async readAgent(target: string, lines = 120): Promise<HerdrPaneReadResult> {
    const result = await this.request("agent.read", {
      target,
      source: "recent_unwrapped",
      format: "text",
      strip_ansi: true,
      lines,
    });
    return readTypedResult<HerdrPaneReadResult>(result, "read", "agent read result");
  }

  async promptAgent(target: string, text: string): Promise<HerdrAgentInfo> {
    const result = await this.request("agent.prompt", { target, text });
    return readTypedResult<HerdrAgentInfo>(result, "agent", "agent prompt result");
  }

  async focusAgent(target: string): Promise<void> {
    await this.request("agent.focus", { target });
  }

  async sendAgentKeys(target: string, keys: ReadonlyArray<string>): Promise<void> {
    await this.request("agent.send_keys", { target, keys });
  }

  async focusPane(paneId: string): Promise<void> {
    await this.request("pane.focus", { pane_id: paneId });
  }

  async splitPane(input: {
    readonly targetPaneId: string;
    readonly cwd: string;
    readonly workspaceId: string;
  }): Promise<HerdrPaneInfo> {
    const result = await this.request("pane.split", {
      direction: "right",
      ratio: 0.5,
      target_pane_id: input.targetPaneId,
      workspace_id: input.workspaceId,
      cwd: input.cwd,
      focus: true,
    });
    return readTypedResult<HerdrPaneInfo>(result, "pane", "split pane");
  }

  async reportPaneMetadata(
    paneId: string,
    tokens: Readonly<Record<string, string | null>>,
    title?: string,
  ): Promise<void> {
    await this.request("pane.report_metadata", {
      pane_id: paneId,
      source: "plugin:t3-code",
      tokens,
      ...(title ? { title } : {}),
    });
  }

  async openPluginPane(input: {
    readonly pluginId: string;
    readonly entrypoint: string;
    readonly workspaceId?: string;
    readonly placement?: "overlay" | "popup" | "split" | "tab" | "zoomed";
  }): Promise<void> {
    await this.request("plugin.pane.open", {
      plugin_id: input.pluginId,
      entrypoint: input.entrypoint,
      placement: input.placement ?? "tab",
      focus: true,
      ...(input.workspaceId ? { workspace_id: input.workspaceId } : {}),
    });
  }

  dispose(): void {
    const socket = this.socket;
    this.socket = null;
    socket?.end();
    socket?.destroy();
    const error = new Error("Herdr client disposed.");
    for (const pending of this.pending.values()) pending.reject(error);
    this.pending.clear();
    this.eventListeners.clear();
    this.disconnectListeners.clear();
  }

  private handleData(chunk: string): void {
    this.buffer += chunk;
    while (true) {
      const newline = this.buffer.indexOf("\n");
      if (newline < 0) return;
      const line = this.buffer.slice(0, newline).trim();
      this.buffer = this.buffer.slice(newline + 1);
      if (line.length === 0) continue;
      const envelope = decodeEnvelope(line);
      if (!envelope) continue;
      if ("id" in envelope) {
        const pending = this.pending.get(envelope.id);
        if (!pending) continue;
        this.pending.delete(envelope.id);
        if ("error" in envelope) {
          pending.reject(new HerdrRpcError(envelope.error.code, envelope.error.message));
        } else {
          pending.resolve(envelope.result);
        }
        continue;
      }
      for (const listener of this.eventListeners) listener(envelope);
    }
  }
}
