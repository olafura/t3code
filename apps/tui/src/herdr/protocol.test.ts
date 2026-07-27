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
  test("correlates fragmented responses and emits lifecycle events", async () => {
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
      })}\n${JSON.stringify({
        event: "pane.agent_status_changed",
        data: { pane_id: "w1:p2", workspace_id: "w1", agent_status: "blocked" },
      })}\n`;
      socket.write(response.slice(0, 13));
      socket.write(response.slice(13));
    });
    const client = new HerdrProtocolClient(fixture.socketPath);
    cleanups.push(async () => client.dispose());
    const events: string[] = [];
    client.onEvent((event) => events.push(event.event));

    const snapshot = await client.snapshot();

    expect(snapshot.protocol).toBe(17);
    expect(events).toEqual(["pane.agent_status_changed"]);
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
          direction: "right",
          ratio: 0.5,
          target_pane_id: "w1:p1",
          workspace_id: "w1",
          cwd: "/repo/worktree",
          focus: true,
        },
      },
    ]);
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
});
