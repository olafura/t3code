// @effect-diagnostics globalTimers:off - This transport runs without an Effect runtime.
/* oxlint-disable unicorn/prefer-add-event-listener -- The socket owns its handlers. */

/**
 * One WebSocket to a protocol-3 node, shared by every environment of its cluster.
 *
 * Subscriptions are multiplexed by id. On reconnect every stream subscription is
 * sent again with the last offset it saw, so the node replays only what was
 * missed; the shell is always re-sent whole because it is small. A `resync` from
 * the node (this client fell too far behind) is handled the same way.
 */

export type ShellShape = { readonly type: "shell" };
export type StreamShape = {
  readonly type: "stream";
  readonly node: string;
  readonly stream: string;
};
export type ConfigShape =
  | { readonly type: "config"; readonly node: string }
  | { readonly type: "config"; readonly environment: string };
export type TerminalShape = {
  readonly type: "terminal";
  readonly node: string;
  readonly input: Readonly<Record<string, unknown>>;
};
export type TerminalsShape = { readonly type: "terminals"; readonly node: string };
export type VcsShape = { readonly type: "vcs"; readonly node: string; readonly cwd: string };
export type ProviderAuthShape = {
  readonly type: "providerAuth";
  readonly node: string;
  readonly instanceId: string;
};
export type WorktreeSetupShape = {
  readonly type: "worktreeSetup";
  readonly node: string;
  readonly threadId: string;
};
export type ScheduledTasksShape = { readonly type: "scheduledTasks"; readonly node: string };
/** Pairing links and clients of the node the socket is connected to. */
export type AuthAccessShape = { readonly type: "authAccess" };
export type ProjectClonesShape = { readonly type: "projectClones"; readonly node: string };
export type PreviewShape = { readonly type: "preview"; readonly node: string };
export type ResourceTelemetryShape = { readonly type: "resourceTelemetry"; readonly node: string };
export type LocalServersShape = { readonly type: "localServers"; readonly node: string };
/** A node's simulators, emulators and open device sessions, whole on every change. */
export type DevicesShape = { readonly type: "devices"; readonly node: string };
/** This client as a node's browser automation host; the node ends it when it drops the host. */
export type PreviewAutomationShape = {
  readonly type: "previewAutomation";
  readonly node: string;
  readonly host: Readonly<Record<string, unknown>>;
};
export type PullRequestRefreshesShape = {
  readonly type: "pullRequestRefreshes";
  readonly node: string;
};
export type GitActionShape = {
  readonly type: "gitAction";
  readonly node: string;
  readonly input: Readonly<Record<string, unknown>>;
};
/** Moves the node to another version (`T3.Upgrade`), streaming progress, then ends. */
export type ServerUpdateShape = {
  readonly type: "serverUpdate";
  readonly node: string;
  readonly input: Readonly<Record<string, unknown>>;
};
export type RelayClientInstallShape = {
  readonly type: "relayClientInstall";
  readonly node: string;
};
export type Shape =
  | ShellShape
  | StreamShape
  | ConfigShape
  | TerminalShape
  | TerminalsShape
  | VcsShape
  | ScheduledTasksShape
  | AuthAccessShape
  | ProjectClonesShape
  | PreviewShape
  | ResourceTelemetryShape
  | LocalServersShape
  | DevicesShape
  | PreviewAutomationShape
  | PullRequestRefreshesShape
  | GitActionShape
  | ServerUpdateShape
  | RelayClientInstallShape
  | ProviderAuthShape
  | WorktreeSetupShape;

/** A failed RPC or subscription; `detail` is the contract error as `{_tag, ...fields}`. */
export class ClusterRpcError extends Error {
  readonly detail: unknown;
  constructor(message: string, detail: unknown) {
    super(message);
    this.detail = detail;
  }
}

/** A server frame addressed to one subscription (`id` already stripped of meaning). */
export type ShapeFrame = Record<string, unknown> & { readonly t: string };

export interface ClusterSocketStatus {
  readonly connected: boolean;
  readonly node: string | null;
}

interface Subscription {
  readonly shape: Shape;
  readonly onFrame: (frame: ShapeFrame) => void;
  offset: number | null;
}

type SocketLike = Pick<WebSocket, "send" | "close" | "readyState"> & {
  onopen: ((event: Event) => void) | null;
  onmessage: ((event: MessageEvent) => void) | null;
  onclose: ((event: CloseEvent) => void) | null;
  onerror: ((event: Event) => void) | null;
};

export interface ClusterSocketOptions {
  /** `ws(s)://host/ws?token=...` of any node in the cluster. */
  readonly url: string;
  readonly createSocket?: (url: string) => SocketLike;
  readonly onStatus?: (status: ClusterSocketStatus) => void;
  readonly retryDelaysMs?: ReadonlyArray<number>;
  /**
   * Reconnect after a drop (default). Off when the URL carries a single-use ticket:
   * the owner then reconnects with a fresh URL instead.
   */
  readonly reconnect?: boolean;
  readonly pingIntervalMs?: number;
}

const OPEN = 1;

export class ClusterSocket {
  private socket: SocketLike | null = null;
  private readonly subscriptions = new Map<number, Subscription>();
  private readonly calls = new Map<
    number,
    { readonly resolve: (value: unknown) => void; readonly reject: (error: Error) => void }
  >();
  private nextId = 1;
  private attempt = 0;
  private node: string | null = null;
  private retryTimer: ReturnType<typeof setTimeout> | null = null;
  private pingTimer: ReturnType<typeof setInterval> | null = null;
  private closed = false;
  // Subscriptions go out only after the node's hello; until then they are queued.
  private ready = false;
  private readonly options: ClusterSocketOptions;

  constructor(options: ClusterSocketOptions) {
    this.options = options;
    this.connect();
  }

  /**
   * Runs an RPC on the node that serves `environment`. Rejects with a
   * `ClusterRpcError` from the node, or when the socket is not connected or drops
   * before the reply.
   */
  call(environment: string, method: string, payload: unknown): Promise<unknown> {
    if (!this.ready) return Promise.reject(new Error("not connected"));
    const id = this.nextId++;
    return new Promise((resolve, reject) => {
      this.calls.set(id, { resolve, reject });
      this.send({ t: "rpc", id, environment, method, payload });
    });
  }

  /** The node this socket is connected to, once it said hello. */
  connectedNode(): string | null {
    return this.node;
  }

  /** Subscribes to a shape; returns the unsubscribe function. */
  subscribe(
    shape: Shape,
    onFrame: (frame: ShapeFrame) => void,
    offset: number | null = null,
  ): () => void {
    const id = this.nextId++;
    this.subscriptions.set(id, { shape, onFrame, offset });
    this.sendSub(id);
    return () => {
      if (this.subscriptions.delete(id)) this.send({ t: "unsub", id });
    };
  }

  close(): void {
    this.closed = true;
    if (this.retryTimer !== null) clearTimeout(this.retryTimer);
    this.stopPing();
    this.socket?.close();
    this.socket = null;
  }

  private connect(): void {
    const create = this.options.createSocket ?? ((url: string) => new WebSocket(url) as SocketLike);
    const socket = create(this.options.url);
    this.socket = socket;
    socket.onmessage = (event) => this.onMessage(String(event.data));
    socket.onclose = () => this.onClose(socket);
    socket.onerror = () => socket.close();
  }

  private onMessage(data: string): void {
    const frame = JSON.parse(data) as ShapeFrame;
    if (frame.t === "hello") {
      this.ready = true;
      this.attempt = 0;
      this.node = typeof frame.node === "string" ? frame.node : null;
      this.startPing();
      for (const id of this.subscriptions.keys()) this.sendSub(id);
      this.options.onStatus?.({ connected: true, node: this.node });
      return;
    }
    if (frame.t === "pong") return;
    const id = typeof frame.id === "number" ? frame.id : null;
    if ((frame.t === "rpc.result" || frame.t === "rpc.error") && id !== null) {
      const call = this.calls.get(id);
      this.calls.delete(id);
      if (frame.t === "rpc.result") call?.resolve(frame.result);
      else call?.reject(new ClusterRpcError(String(frame.error), frame.detail));
      return;
    }
    const subscription = id === null ? undefined : this.subscriptions.get(id);
    if (subscription === undefined || id === null) return;
    if (frame.t === "resync") {
      subscription.offset = typeof frame.offset === "number" ? frame.offset : null;
      this.sendSub(id);
      return;
    }
    // The node ended the shape and already forgot it.
    if (frame.t === "end") this.subscriptions.delete(id);
    if ((frame.t === "events" || frame.t === "live") && typeof frame.offset === "number") {
      subscription.offset = frame.offset;
    }
    subscription.onFrame(frame);
  }

  private onClose(socket: SocketLike): void {
    if (socket !== this.socket) return;
    this.socket = null;
    this.ready = false;
    for (const call of this.calls.values()) call.reject(new Error("disconnected"));
    this.calls.clear();
    this.stopPing();
    this.options.onStatus?.({ connected: false, node: this.node });
    if (this.closed || this.options.reconnect === false) return;
    const delays = this.options.retryDelaysMs ?? [500, 1_000, 2_000, 4_000, 8_000];
    const delay = delays[Math.min(this.attempt, delays.length - 1)] ?? 8_000;
    this.attempt++;
    this.retryTimer = setTimeout(() => {
      this.retryTimer = null;
      this.connect();
    }, delay);
  }

  private sendSub(id: number): void {
    const subscription = this.subscriptions.get(id);
    if (subscription === undefined || !this.ready) return;
    const offset = subscription.shape.type === "stream" ? subscription.offset : null;
    this.send({ t: "sub", id, shape: subscription.shape, offset });
  }

  private send(message: unknown): void {
    if (this.socket?.readyState === OPEN) this.socket.send(JSON.stringify(message));
  }

  private startPing(): void {
    this.stopPing();
    this.pingTimer = setInterval(
      () => this.send({ t: "ping" }),
      this.options.pingIntervalMs ?? 25_000,
    );
  }

  private stopPing(): void {
    if (this.pingTimer !== null) clearInterval(this.pingTimer);
    this.pingTimer = null;
  }
}
