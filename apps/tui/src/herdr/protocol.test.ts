import { afterEach, describe, expect, test } from "bun:test";
import * as NodeFSP from "node:fs/promises";
import * as NodeNet from "node:net";
import * as NodeOS from "node:os";
import * as NodePath from "node:path";

import { HerdrProtocolClient, HerdrRpcError } from "./protocol.ts";

type RequestEnvelope = {
  readonly id: string;
  readonly method: string;
  readonly params: Readonly<Record<string, unknown>>;
};

const cleanups: Array<() => Promise<void>> = [];

afterEach(async () => {
  while (cleanups.length > 0) await cleanups.pop()?.();
});

async function withServer(
  onRequest: (request: RequestEnvelope, socket: NodeNet.Socket) => void,
): Promise<{ readonly socketPath: string; readonly requests: RequestEnvelope[] }> {
  const directory = await NodeFSP.mkdtemp(NodePath.join(NodeOS.tmpdir(), "t3-herdr-protocol-"));
  const socketPath = NodePath.join(directory, "herdr.sock");
  const requests: RequestEnvelope[] = [];
  const server = NodeNet.createServer((socket) => {
    socket.setEncoding("utf8");
    let buffer = "";
    socket.on("data", (chunk: string) => {
      buffer += chunk;
      while (true) {
        const newline = buffer.indexOf("\n");
        if (newline < 0) return;
        const line = buffer.slice(0, newline);
        buffer = buffer.slice(newline + 1);
        if (!line.trim()) continue;
        const request = JSON.parse(line) as RequestEnvelope;
        requests.push(request);
        onRequest(request, socket);
      }
    });
  });
  await new Promise<void>((resolve, reject) => {
    server.once("error", reject);
    server.listen(socketPath, resolve);
  });
  cleanups.push(async () => {
    await new Promise<void>((resolve) => server.close(() => resolve()));
    await NodeFSP.rm(directory, { recursive: true, force: true });
  });
  return { socketPath, requests };
}

describe("HerdrProtocolClient", () => {
  test("correlates fragmented ordinary responses", async () => {
    const fixture = await withServer((request, socket) => {
      if (request.method !== "session.snapshot") return;
      const response = `${JSON.stringify({
        id: request.id,
        result: {
          type: "session_snapshot",
          snapshot: {
            version: "0.7.5",
            protocol: 17,
            workspaces: [],
            tabs: [],
            panes: [],
            layouts: [],
            agents: [],
          },
        },
      })}\n`;
      socket.write(response.slice(0, 13));
      socket.write(response.slice(13));
    });
    const client = new HerdrProtocolClient(fixture.socketPath);
    cleanups.push(async () => client.dispose());
    const snapshot = await client.snapshot();

    expect(snapshot.protocol).toBe(17);
  });

  test("preserves request shapes for agent prompting and pane splitting", async () => {
    const fixture = await withServer((request, socket) => {
      if (request.method === "agent.prompt") {
        socket.write(
          `${JSON.stringify({
            id: request.id,
            result: {
              type: "agent_info",
              agent: {
                pane_id: "w1:p2",
                terminal_id: "term-2",
                workspace_id: "w1",
                tab_id: "w1:t1",
                focused: false,
                agent_status: "working",
                revision: 1,
              },
            },
          })}\n`,
        );
      } else if (request.method === "pane.split") {
        socket.write(
          `${JSON.stringify({
            id: request.id,
            result: {
              type: "pane_split",
              pane: {
                pane_id: "w1:p3",
                terminal_id: "term-3",
                workspace_id: "w1",
                tab_id: "w1:t1",
                focused: true,
                agent_status: "unknown",
                revision: 0,
              },
            },
          })}\n`,
        );
      }
    });
    const client = new HerdrProtocolClient(fixture.socketPath);
    cleanups.push(async () => client.dispose());

    await client.promptAgent("reviewer", "Review this");
    await client.splitPane({
      targetPaneId: "w1:p1",
      workspaceId: "w1",
      cwd: "/repo/worktree",
      direction: "down",
      ratio: 0.62,
    });

    expect(fixture.requests).toEqual([
      {
        id: "t3_1",
        method: "agent.prompt",
        params: { target: "reviewer", text: "Review this" },
      },
      {
        id: "t3_2",
        method: "pane.split",
        params: {
          direction: "down",
          ratio: 0.62,
          target_pane_id: "w1:p1",
          workspace_id: "w1",
          cwd: "/repo/worktree",
          focus: true,
        },
      },
    ]);
  });

  test("uses a fresh connection for each ordinary request", async () => {
    const fixture = await withServer((request, socket) => {
      if (request.method === "ping") {
        socket.end(
          `${JSON.stringify({
            id: request.id,
            result: { type: "pong", version: "0.7.5", protocol: 17 },
          })}\n`,
        );
        return;
      }
      socket.end(
        `${JSON.stringify({
          id: request.id,
          result: {
            type: "session_snapshot",
            snapshot: {
              version: "0.7.5",
              protocol: 17,
              workspaces: [],
              tabs: [],
              panes: [],
              layouts: [],
              agents: [],
            },
          },
        })}\n`,
      );
    });
    const client = new HerdrProtocolClient(fixture.socketPath);
    cleanups.push(async () => client.dispose());

    await expect(client.ping()).resolves.toEqual({ version: "0.7.5", protocol: 17 });
    await expect(client.snapshot()).resolves.toMatchObject({ protocol: 17 });
    expect(fixture.requests.map((request) => request.method)).toEqual(["ping", "session.snapshot"]);
  });

  test("subscribes only to lifecycle events that support an unscoped stream", async () => {
    const fixture = await withServer((request, socket) => {
      const result =
        request.method === "events.subscribe"
          ? { type: "subscription_started" }
          : { type: "pong", version: "0.7.5", protocol: 17 };
      socket.write(`${JSON.stringify({ id: request.id, result })}\n`);
      if (request.method === "events.subscribe") {
        socket.write(
          `${JSON.stringify({
            event: "pane.created",
            data: { pane_id: "w1:p2", workspace_id: "w1" },
          })}\n`,
        );
      }
    });
    const client = new HerdrProtocolClient(fixture.socketPath);
    cleanups.push(async () => client.dispose());
    const events: string[] = [];
    client.onEvent((event) => events.push(event.event));

    await client.subscribeToLifecycleEvents();
    await expect(client.ping()).resolves.toEqual({ version: "0.7.5", protocol: 17 });

    const subscriptions = fixture.requests[0]?.params.subscriptions as ReadonlyArray<{
      readonly type: string;
    }>;
    expect(subscriptions.some((subscription) => subscription.type === "pane.created")).toBe(true);
    expect(
      subscriptions.some((subscription) => subscription.type === "pane.agent_status_changed"),
    ).toBe(false);
    expect(events).toEqual(["pane.created"]);
  });

  test("surfaces declared Herdr errors", async () => {
    const fixture = await withServer((request, socket) => {
      socket.write(
        `${JSON.stringify({
          id: request.id,
          error: { code: "agent_not_running", message: "agent exited" },
        })}\n`,
      );
    });
    const client = new HerdrProtocolClient(fixture.socketPath);
    cleanups.push(async () => client.dispose());

    await expect(client.focusAgent("gone")).rejects.toEqual(
      new HerdrRpcError("agent_not_running", "agent exited"),
    );
  });

  test("sends portable Herdr key chords to a native agent", async () => {
    const fixture = await withServer((request, socket) => {
      socket.write(`${JSON.stringify({ id: request.id, result: { type: "agent_keys_sent" } })}\n`);
    });
    const client = new HerdrProtocolClient(fixture.socketPath);
    cleanups.push(async () => client.dispose());

    await client.sendAgentKeys("w1:p2", ["ctrl+c"]);

    expect(fixture.requests[0]).toEqual({
      id: "t3_1",
      method: "agent.send_keys",
      params: { target: "w1:p2", keys: ["ctrl+c"] },
    });
  });

  test("reports a T3 thread through Herdr's semantic agent state", async () => {
    const fixture = await withServer((request, socket) => {
      socket.write(`${JSON.stringify({ id: request.id, result: { type: "ok" } })}\n`);
    });
    const client = new HerdrProtocolClient(fixture.socketPath);
    cleanups.push(async () => client.dispose());

    await client.reportPaneAgent({
      paneId: "w1:p2",
      source: "plugin:dev.t3code",
      agent: "t3-code",
      state: "working",
      message: "Fix terminal integration",
      sessionId: "thread-1",
    });

    expect(fixture.requests[0]).toEqual({
      id: "t3_1",
      method: "pane.report_agent",
      params: {
        pane_id: "w1:p2",
        source: "plugin:dev.t3code",
        agent: "t3-code",
        state: "working",
        message: "Fix terminal integration",
        agent_session_id: "thread-1",
      },
    });
  });
});
