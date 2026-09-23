import { describe, expect, it, vi } from "vite-plus/test";

import { ClusterSocket, type ShapeFrame } from "./clusterSocket.ts";

class FakeSocket {
  readyState: WebSocket["readyState"] = 0;
  sent: Array<Record<string, unknown>> = [];
  onopen: ((event: Event) => void) | null = null;
  onmessage: ((event: MessageEvent) => void) | null = null;
  onclose: ((event: CloseEvent) => void) | null = null;
  onerror: ((event: Event) => void) | null = null;

  send(data: string) {
    this.sent.push(JSON.parse(data));
  }
  close() {
    this.readyState = 3;
    this.onclose?.({} as CloseEvent);
  }
  serve(frame: Record<string, unknown>) {
    this.readyState = 1;
    this.onmessage?.({ data: JSON.stringify(frame) } as MessageEvent);
  }
}

function setup() {
  const sockets: FakeSocket[] = [];
  const socket = new ClusterSocket({
    url: "ws://node/ws",
    createSocket: () => {
      const fake = new FakeSocket();
      sockets.push(fake);
      return fake;
    },
    retryDelaysMs: [10],
    pingIntervalMs: 60_000,
  });
  return { socket, sockets };
}

describe("ClusterSocket", () => {
  it("subscribes after hello and routes frames by subscription", () => {
    const { socket, sockets } = setup();
    const frames: ShapeFrame[] = [];
    socket.subscribe({ type: "shell" }, (frame) => frames.push(frame));
    const [first] = sockets;
    first!.serve({ t: "hello", node: "t3@a", protocol: 3 });
    expect(first!.sent).toEqual([{ t: "sub", id: 1, shape: { type: "shell" }, offset: null }]);

    first!.serve({ t: "shell", id: 1, rows: [] });
    first!.serve({ t: "shell", id: 99, rows: [] });
    expect(frames).toEqual([{ t: "shell", id: 1, rows: [] }]);
    socket.close();
  });

  it("reconnects and resumes each stream from the last offset it saw", async () => {
    vi.useFakeTimers();
    const { socket, sockets } = setup();
    const shape = { type: "stream", node: "t3@b", stream: "thread-1" } as const;
    socket.subscribe(shape, () => {});
    sockets[0]!.serve({ t: "hello", node: "t3@a" });
    sockets[0]!.serve({ t: "live", id: 1, offset: 40 });
    sockets[0]!.serve({ t: "events", id: 1, offset: 42, events: [] });

    sockets[0]!.close();
    await vi.advanceTimersByTimeAsync(10);
    sockets[1]!.serve({ t: "hello", node: "t3@a" });
    expect(sockets[1]!.sent).toEqual([{ t: "sub", id: 1, shape, offset: 42 }]);
    socket.close();
    vi.useRealTimers();
  });

  it("a resync resubscribes from the offset the node names", () => {
    const { socket, sockets } = setup();
    const frames: ShapeFrame[] = [];
    socket.subscribe({ type: "stream", node: "t3@b", stream: "thread-1" }, (frame) =>
      frames.push(frame),
    );
    sockets[0]!.serve({ t: "hello", node: "t3@a" });
    sockets[0]!.serve({ t: "resync", id: 1, offset: 7 });
    expect(sockets[0]!.sent.at(-1)).toMatchObject({ t: "sub", id: 1, offset: 7 });
    expect(frames).toEqual([]);
    socket.close();
  });
});
