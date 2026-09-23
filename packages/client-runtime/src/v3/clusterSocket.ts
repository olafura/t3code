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
export type ConfigShape = { readonly type: "config"; readonly node: string };
export type Shape = ShellShape | StreamShape | ConfigShape;

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
    const subscription = id === null ? undefined : this.subscriptions.get(id);
    if (subscription === undefined || id === null) return;
    if (frame.t === "resync") {
      subscription.offset = typeof frame.offset === "number" ? frame.offset : null;
      this.sendSub(id);
      return;
    }
    if ((frame.t === "events" || frame.t === "live") && typeof frame.offset === "number") {
      subscription.offset = frame.offset;
    }
    subscription.onFrame(frame);
  }

  private onClose(socket: SocketLike): void {
    if (socket !== this.socket) return;
    this.socket = null;
    this.ready = false;
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
