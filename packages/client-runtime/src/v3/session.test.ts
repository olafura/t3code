import * as Effect from "effect/Effect";
import * as Stream from "effect/Stream";
import { describe, expect, it, vi } from "vite-plus/test";

import { ClusterSocket } from "./clusterSocket.ts";
import { shapeStream } from "./session.ts";

class FakeSocket {
  readyState: WebSocket["readyState"] = 0;
  onopen: ((event: Event) => void) | null = null;
  onmessage: ((event: MessageEvent) => void) | null = null;
  onclose: ((event: CloseEvent) => void) | null = null;
  onerror: ((event: Event) => void) | null = null;

  sent: Array<Record<string, unknown>> = [];

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

describe("shapeStream", () => {
  it("completes when the node ends the shape", async () => {
    const fake = new FakeSocket();
    const socket = new ClusterSocket({
      url: "ws://node/ws",
      createSocket: () => fake,
      retryDelaysMs: [10],
      pingIntervalMs: 60_000,
    });
    fake.serve({ t: "hello", node: "t3@a", protocol: 3 });

    const items = Effect.runPromise(
      shapeStream(socket, { type: "serverUpdate", node: "t3@a", input: {} }, (frame) =>
        frame.t === "serverUpdate" ? [frame.event] : [],
      ).pipe(Stream.runCollect),
    );
    await vi.waitFor(() => expect(fake.sent[0]).toMatchObject({ t: "sub", id: 1 }));
    fake.serve({ t: "serverUpdate", id: 1, event: "installing" });
    fake.serve({ t: "serverUpdate", id: 1, event: "complete" });
    fake.serve({ t: "end", id: 1 });

    expect(Array.from(await items)).toEqual(["installing", "complete"]);
    socket.close();
  });
});
