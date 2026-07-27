import type { TerminalAttachStreamEvent, ThreadId } from "@t3tools/contracts";

import { buildTuiRuntime, makeTuiClient, type TuiClient } from "../connection.ts";

export const HERDR_TERMINAL_BRIDGE_FLAG = "--herdr-terminal-bridge";

export interface HerdrTerminalBridgeOptions {
  readonly socketUrl: string;
  readonly origin: string;
  readonly threadId: string;
  readonly terminalId: string;
  readonly cwd: string;
  readonly worktreePath: string | null;
  readonly logPath: string;
}

function required(values: ReadonlyMap<string, string>, name: string): string {
  const value = values.get(name);
  if (!value) throw new Error(`missing ${name}`);
  return value;
}

export function parseHerdrTerminalBridgeArgs(
  args: ReadonlyArray<string>,
): HerdrTerminalBridgeOptions {
  const values = new Map<string, string>();
  for (let index = 0; index < args.length; index += 2) {
    const name = args[index];
    const value = args[index + 1];
    if (!name?.startsWith("--") || value === undefined) {
      throw new Error("invalid Herdr terminal bridge arguments");
    }
    values.set(name, value);
  }
  const worktreePath = values.get("--worktree-path");
  return {
    socketUrl: required(values, "--socket-url"),
    origin: required(values, "--origin"),
    threadId: required(values, "--thread-id"),
    terminalId: required(values, "--terminal-id"),
    cwd: required(values, "--cwd"),
    worktreePath: worktreePath && worktreePath !== "-" ? worktreePath : null,
    logPath: values.get("--log-path") ?? "/tmp/t3-herdr-terminal.log",
  };
}

export function terminalBridgeOutput(event: TerminalAttachStreamEvent): string {
  switch (event.type) {
    case "snapshot":
      return `\u001b[2J\u001b[H${event.snapshot.history}`;
    case "output":
      return event.data;
    case "restarted":
      return `\u001b[2J\u001b[H${event.snapshot.history}`;
    case "cleared":
      return "\u001b[2J\u001b[H";
    case "exited":
      return `\r\n[T3 terminal exited${event.exitCode === null ? "" : ` (${event.exitCode})`}]\r\n`;
    case "error":
      return `\r\n[T3 terminal error: ${event.message}]\r\n`;
    case "closed":
      return "\r\n[T3 terminal closed]\r\n";
    case "activity":
      return "";
  }
}

export async function runHerdrTerminalBridge(
  args: ReadonlyArray<string>,
  dependencies: {
    readonly makeClient?: (options: HerdrTerminalBridgeOptions) => {
      readonly client: TuiClient;
      readonly dispose: () => Promise<void>;
    };
  } = {},
): Promise<void> {
  const options = parseHerdrTerminalBridgeArgs(args);
  let socketUrlAvailable = true;
  const runtime = dependencies.makeClient
    ? null
    : buildTuiRuntime({
        origin: options.origin,
        bearerToken: "herdr-terminal-bridge",
        mintSocketUrl: async () => {
          if (!socketUrlAvailable) throw new Error("terminal bridge connection closed");
          socketUrlAvailable = false;
          return options.socketUrl;
        },
        logPath: options.logPath,
      });
  const injected = dependencies.makeClient?.(options);
  const client = injected?.client ?? makeTuiClient(runtime!, options.origin);
  const dispose = injected?.dispose ?? (() => client.dispose());
  const threadId = options.threadId as ThreadId;
  const stdin = process.stdin;
  const stdout = process.stdout;
  const cols = () => Math.max(1, stdout.columns ?? 80);
  const rows = () => Math.max(1, stdout.rows ?? 24);

  let unsubscribe = () => {};
  const onInput = (data: Buffer) => {
    void client
      .terminalWrite(threadId, options.terminalId, data.toString("utf8"), "terminal")
      .catch(() => {});
  };
  const onResize = () => {
    void client.terminalResize(threadId, options.terminalId, cols(), rows()).catch(() => {});
  };
  let finish = () => {};
  const onSignal = () => finish();
  await new Promise<void>((resolve) => {
    let settled = false;
    finish = () => {
      if (settled) return;
      settled = true;
      resolve();
    };
    unsubscribe = client.subscribeTerminal(
      {
        threadId,
        terminalId: options.terminalId,
        cwd: options.cwd,
        worktreePath: options.worktreePath,
        cols: cols(),
        rows: rows(),
      },
      (event) => {
        const output = terminalBridgeOutput(event);
        if (output) stdout.write(output);
        if (event.type === "closed") finish();
      },
    );
    stdin.setRawMode?.(true);
    stdin.resume();
    stdin.on("data", onInput);
    process.on("SIGWINCH", onResize);
    process.once("SIGINT", onSignal);
    process.once("SIGTERM", onSignal);
  });
  unsubscribe();
  stdin.off("data", onInput);
  process.off("SIGWINCH", onResize);
  process.off("SIGINT", onSignal);
  process.off("SIGTERM", onSignal);
  stdin.setRawMode?.(false);
  await dispose();
}
