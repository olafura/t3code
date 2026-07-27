import { describe, expect, test } from "bun:test";

import {
  createHerdrTerminalInputParser,
  encodeHerdrTerminalSwitch,
  parseHerdrTerminalBridgeArgs,
  terminalBridgeOutput,
  type HerdrTerminalTarget,
} from "./terminalBridge.ts";

const target = {
  socketUrl: "ws://127.0.0.1/ws?wsTicket=one",
  origin: "http://127.0.0.1:5733",
  threadId: "thread-1",
  terminalId: "term-2",
  cwd: "/repo",
  worktreePath: null,
} satisfies HerdrTerminalTarget;

describe("Herdr terminal bridge", () => {
  test("parses one server-backed terminal identity and its Herdr dashboard", () => {
    expect(
      parseHerdrTerminalBridgeArgs([
        "--socket-url",
        target.socketUrl,
        "--origin",
        target.origin,
        "--thread-id",
        target.threadId,
        "--terminal-id",
        target.terminalId,
        "--cwd",
        target.cwd,
        "--worktree-path",
        "-",
        "--herdr-socket-path",
        "/tmp/herdr.sock",
        "--dashboard-pane-id",
        "w1:p1",
      ]),
    ).toMatchObject({
      threadId: "thread-1",
      terminalId: "term-2",
      cwd: "/repo",
      worktreePath: null,
      herdrSocketPath: "/tmp/herdr.sock",
      dashboardPaneId: "w1:p1",
    });
  });

  test("switches terminals without leaking private control bytes into the PTY", () => {
    const input: string[] = [];
    const switches: HerdrTerminalTarget[] = [];
    const parser = createHerdrTerminalInputParser({
      onInput: (data) => input.push(data),
      onSwitch: (value) => switches.push(value),
    });
    const frame = encodeHerdrTerminalSwitch(target);

    parser.push(`git st\r${frame.slice(0, 9)}`);
    parser.push(`${frame.slice(9)}pwd\r`);
    parser.flush();

    expect(input.join("")).toBe("git st\rpwd\r");
    expect(switches).toEqual([target]);
  });

  test("preserves ordinary escape input that only resembles a control prefix", () => {
    const input: string[] = [];
    const parser = createHerdrTerminalInputParser({
      onInput: (data) => input.push(data),
      onSwitch: () => {},
    });

    parser.push("\u001b");
    parser.push("[A");
    parser.flush();

    expect(input.join("")).toBe("\u001b[A");
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
