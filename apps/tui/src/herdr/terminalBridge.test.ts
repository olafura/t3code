import { describe, expect, test } from "bun:test";

import { parseHerdrTerminalBridgeArgs, terminalBridgeOutput } from "./terminalBridge.ts";

describe("Herdr terminal bridge", () => {
  test("parses one server-backed terminal identity", () => {
    expect(
      parseHerdrTerminalBridgeArgs([
        "--socket-url",
        "ws://127.0.0.1/ws?wsTicket=one",
        "--origin",
        "http://127.0.0.1:5733",
        "--thread-id",
        "thread-1",
        "--terminal-id",
        "term-2",
        "--cwd",
        "/repo",
        "--worktree-path",
        "-",
      ]),
    ).toMatchObject({
      threadId: "thread-1",
      terminalId: "term-2",
      cwd: "/repo",
      worktreePath: null,
    });
  });

  test("replaces the native pane with the authoritative terminal snapshot", () => {
    expect(
      terminalBridgeOutput({
        type: "snapshot",
        snapshot: {
          threadId: "thread-1",
          terminalId: "term-1",
          cwd: "/repo",
          worktreePath: null,
          status: "running",
          pid: 123,
          history: "shared history",
          exitCode: null,
          exitSignal: null,
          label: "shell",
          updatedAt: "2026-07-27T00:00:00.000Z",
        },
      }),
    ).toBe("\u001b[2J\u001b[Hshared history");
  });
});
