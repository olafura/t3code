import * as NodeNet from "node:net";

export const HERDR_MIN_PROTOCOL = 17;

export type HerdrAgentStatus = "idle" | "working" | "blocked" | "done" | "unknown";
export type HerdrReportedAgentState = Exclude<HerdrAgentStatus, "done">;

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
  private eventSocket: NodeNet.Socket | null = null;
  private subscribing: Promise<void> | null = null;
  private eventBuffer = "";
  private nextRequestId = 1;
  private readonly requestSockets = new Set<NodeNet.Socket>();
  private readonly eventListeners = new Set<(event: HerdrEventEnvelope) => void>();
  private readonly disconnectListeners = new Set<(error: Error) => void>();

  constructor(socketPath: string, socketFactory: SocketFactory = NodeNet.createConnection) {
    this.socketPath = socketPath;
    this.socketFactory = socketFactory;
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
    const id = `t3_${this.nextRequestId++}`;
    return new Promise<Readonly<Record<string, unknown>>>((resolve, reject) => {
      const socket = this.socketFactory(this.socketPath);
      this.requestSockets.add(socket);
      let buffer = "";
      let settled = false;

      const finish = (error: Error | null, result?: Readonly<Record<string, unknown>>): void => {
        if (settled) return;
        settled = true;
        this.requestSockets.delete(socket);
        socket.end();
        socket.destroy();
        if (error) reject(error);
        else resolve(result ?? {});
      };

      socket.setEncoding("utf8");
      socket.on("data", (chunk: string) => {
        buffer += chunk;
        while (true) {
          const newline = buffer.indexOf("\n");
          if (newline < 0) return;
          const line = buffer.slice(0, newline).trim();
          buffer = buffer.slice(newline + 1);
          if (line.length === 0) continue;
          const envelope = decodeEnvelope(line);
          if (!envelope) continue;
          if (!("id" in envelope)) {
            for (const listener of this.eventListeners) listener(envelope);
            continue;
          }
          if (envelope.id !== id) continue;
          if ("error" in envelope) {
            finish(new HerdrRpcError(envelope.error.code, envelope.error.message));
          } else {
            finish(null, envelope.result);
          }
          return;
        }
      });
      socket.once("connect", () => {
        socket.write(`${JSON.stringify({ id, method, params })}\n`, (error) => {
          if (error) finish(error);
        });
      });
      socket.once("error", (cause) => {
        finish(cause instanceof Error ? cause : new Error(String(cause)));
      });
      socket.once("close", () => {
        finish(new Error("Herdr socket disconnected before responding."));
      });
    });
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
    if (this.eventSocket && !this.eventSocket.destroyed) return;
    if (this.subscribing) return this.subscribing;

    const id = `t3_${this.nextRequestId++}`;
    this.subscribing = new Promise<void>((resolve, reject) => {
      let acknowledged = false;
      const socket = this.socketFactory(this.socketPath);
      this.eventSocket = socket;
      socket.setEncoding("utf8");
      socket.on("data", (chunk: string) => {
        this.eventBuffer += chunk;
        while (true) {
          const newline = this.eventBuffer.indexOf("\n");
          if (newline < 0) return;
          const line = this.eventBuffer.slice(0, newline).trim();
          this.eventBuffer = this.eventBuffer.slice(newline + 1);
          if (line.length === 0) continue;
          const envelope = decodeEnvelope(line);
          if (!envelope) continue;
          if ("id" in envelope) {
            if (envelope.id !== id || acknowledged) continue;
            if ("error" in envelope) {
              reject(new HerdrRpcError(envelope.error.code, envelope.error.message));
            } else {
              acknowledged = true;
              resolve();
            }
            continue;
          }
          for (const listener of this.eventListeners) listener(envelope);
        }
      });
      socket.once("connect", () => {
        socket.write(
          `${JSON.stringify({
            id,
            method: "events.subscribe",
            params: {
              subscriptions: DEFAULT_EVENT_SUBSCRIPTIONS.map((type) => ({ type })),
            },
          })}\n`,
          (error) => {
            if (error && !acknowledged) reject(error);
          },
        );
      });
      socket.once("error", (cause) => {
        if (acknowledged) return;
        reject(cause instanceof Error ? cause : new Error(String(cause)));
      });
      socket.once("close", () => {
        const error = new Error("Herdr event stream disconnected.");
        if (this.eventSocket === socket) this.eventSocket = null;
        this.eventBuffer = "";
        if (!acknowledged) reject(error);
        for (const listener of this.disconnectListeners) listener(error);
      });
    }).finally(() => {
      this.subscribing = null;
    });
    return this.subscribing;
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
    readonly direction: "right" | "down";
    readonly ratio?: number;
  }): Promise<HerdrPaneInfo> {
    const result = await this.request("pane.split", {
      direction: input.direction,
      ratio: input.ratio ?? 0.5,
      target_pane_id: input.targetPaneId,
      workspace_id: input.workspaceId,
      cwd: input.cwd,
      focus: true,
    });
    return readTypedResult<HerdrPaneInfo>(result, "pane", "split pane");
  }

  async createTab(input: {
    readonly workspaceId: string;
    readonly cwd: string;
    readonly label: string;
    readonly focus?: boolean;
  }): Promise<HerdrPaneInfo> {
    const result = await this.request("tab.create", {
      workspace_id: input.workspaceId,
      cwd: input.cwd,
      label: input.label,
      focus: input.focus ?? true,
    });
    return readTypedResult<HerdrPaneInfo>(result, "root_pane", "tab root pane");
  }

  async sendPaneInput(
    paneId: string,
    text: string,
    keys: ReadonlyArray<string> = [],
  ): Promise<void> {
    await this.request("pane.send_input", {
      pane_id: paneId,
      text,
      keys,
    });
  }

  async closePane(paneId: string): Promise<void> {
    await this.request("pane.close", { pane_id: paneId });
  }

  async reportPaneAgent(input: {
    readonly paneId: string;
    readonly source: string;
    readonly agent: string;
    readonly state: HerdrReportedAgentState;
    readonly message?: string;
    readonly sessionId?: string;
  }): Promise<void> {
    await this.request("pane.report_agent", {
      pane_id: input.paneId,
      source: input.source,
      agent: input.agent,
      state: input.state,
      ...(input.message ? { message: input.message } : {}),
      ...(input.sessionId ? { agent_session_id: input.sessionId } : {}),
    });
  }

  async releasePaneAgent(input: {
    readonly paneId: string;
    readonly source: string;
    readonly agent: string;
  }): Promise<void> {
    await this.request("pane.release_agent", {
      pane_id: input.paneId,
      source: input.source,
      agent: input.agent,
    });
  }

  async reportPaneMetadata(input: {
    readonly paneId: string;
    readonly source: string;
    readonly tokens: Readonly<Record<string, string | null>>;
    readonly title?: string;
    readonly displayAgent?: string;
  }): Promise<void> {
    await this.request("pane.report_metadata", {
      pane_id: input.paneId,
      source: input.source,
      tokens: input.tokens,
      ...(input.title ? { title: input.title } : {}),
      ...(input.displayAgent ? { display_agent: input.displayAgent } : {}),
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
    const eventSocket = this.eventSocket;
    this.eventSocket = null;
    for (const socket of this.requestSockets) {
      socket.end();
      socket.destroy();
    }
    this.requestSockets.clear();
    eventSocket?.end();
    eventSocket?.destroy();
    this.eventListeners.clear();
    this.disconnectListeners.clear();
  }
}
