import type { TerminalAttachStreamEvent, ThreadId } from "@t3tools/contracts";

import { buildTuiRuntime, makeTuiClient, type TuiClient } from "../connection.ts";
import { HerdrProtocolClient } from "./protocol.ts";

export const HERDR_TERMINAL_BRIDGE_FLAG = "--herdr-terminal-bridge";

const CONTROL_PREFIX = "\u001bP+t3-terminal;";
const CONTROL_SUFFIX = "\u001b\\";
const FOCUS_DASHBOARD = "\u0010";
const CLOSE_TERMINAL = "\u0005";

export interface HerdrTerminalTarget {
  readonly origin: string;
  readonly threadId: string;
  readonly terminalId: string;
  readonly cwd: string;
  readonly worktreePath: string | null;
}

export interface HerdrTerminalLaunchTarget extends HerdrTerminalTarget {
  readonly socketUrl: string;
}

export interface HerdrTerminalBridgeOptions extends HerdrTerminalLaunchTarget {
  readonly herdrSocketPath: string;
  readonly dashboardPaneId: string;
  readonly terminalPaneId: string;
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
    herdrSocketPath: required(values, "--herdr-socket-path"),
    dashboardPaneId: required(values, "--dashboard-pane-id"),
    terminalPaneId: required(values, "--terminal-pane-id"),
    logPath: values.get("--log-path") ?? "/tmp/t3-herdr-terminal.log",
  };
}

export function routeHerdrTerminalShortcuts(
  data: string,
  handlers: {
    readonly onInput: (data: string) => void;
    readonly onFocusDashboard: () => void;
    readonly onCloseTerminal: () => void;
  },
): void {
  let start = 0;
  for (let index = 0; index < data.length; index += 1) {
    const value = data[index];
    if (value !== FOCUS_DASHBOARD && value !== CLOSE_TERMINAL) continue;
    if (index > start) handlers.onInput(data.slice(start, index));
    if (value === FOCUS_DASHBOARD) handlers.onFocusDashboard();
    else handlers.onCloseTerminal();
    start = index + 1;
  }
  if (start < data.length) handlers.onInput(data.slice(start));
}

export function encodeHerdrTerminalSwitch(target: HerdrTerminalTarget): string {
  const payload = Buffer.from(JSON.stringify(target), "utf8").toString("base64url");
  return `${CONTROL_PREFIX}${payload}${CONTROL_SUFFIX}`;
}

export function createHerdrTerminalInputParser(input: {
  readonly onInput: (data: string) => void;
  readonly onSwitch: (target: HerdrTerminalTarget) => void;
}): { readonly push: (data: string) => void; readonly flush: () => void } {
  let buffered = "";

  const trailingPrefixLength = (value: string): number => {
    const maximum = Math.min(value.length, CONTROL_PREFIX.length - 1);
    for (let length = maximum; length > 0; length -= 1) {
      if (value.endsWith(CONTROL_PREFIX.slice(0, length))) return length;
    }
    return 0;
  };

  const drain = () => {
    while (buffered.length > 0) {
      const start = buffered.indexOf(CONTROL_PREFIX);
      if (start < 0) {
        const retained = trailingPrefixLength(buffered);
        const ready = buffered.slice(0, buffered.length - retained);
        buffered = buffered.slice(buffered.length - retained);
        if (ready) input.onInput(ready);
        return;
      }
      if (start > 0) {
        input.onInput(buffered.slice(0, start));
        buffered = buffered.slice(start);
      }
      const end = buffered.indexOf(CONTROL_SUFFIX, CONTROL_PREFIX.length);
      if (end < 0) return;
      const encoded = buffered.slice(CONTROL_PREFIX.length, end);
      buffered = buffered.slice(end + CONTROL_SUFFIX.length);
      try {
        const parsed = JSON.parse(
          Buffer.from(encoded, "base64url").toString("utf8"),
        ) as Partial<HerdrTerminalTarget>;
        if (
          typeof parsed.origin === "string" &&
          typeof parsed.threadId === "string" &&
          typeof parsed.terminalId === "string" &&
          typeof parsed.cwd === "string" &&
          (typeof parsed.worktreePath === "string" || parsed.worktreePath === null)
        ) {
          input.onSwitch(parsed as HerdrTerminalTarget);
        }
      } catch {
        // Private malformed control frames are discarded instead of reaching the PTY.
      }
    }
  };

  return {
    push: (data) => {
      buffered += data;
      drain();
    },
    flush: () => {
      if (buffered) input.onInput(buffered);
      buffered = "";
    },
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
    readonly makeClient?: (target: HerdrTerminalLaunchTarget) => {
      readonly client: TuiClient;
      readonly dispose: () => Promise<void>;
    };
    readonly focusDashboard?: () => Promise<void>;
    readonly closeTerminal?: () => Promise<void>;
  } = {},
): Promise<void> {
  const options = parseHerdrTerminalBridgeArgs(args);
  const stdin = process.stdin;
  const stdout = process.stdout;
  const cols = () => Math.max(1, stdout.columns ?? 80);
  const rows = () => Math.max(1, stdout.rows ?? 24);
  const herdr =
    dependencies.focusDashboard && dependencies.closeTerminal
      ? null
      : new HerdrProtocolClient(options.herdrSocketPath);
  const focusDashboard =
    dependencies.focusDashboard ?? (() => herdr!.focusPane(options.dashboardPaneId));
  const closeTerminal =
    dependencies.closeTerminal ??
    (async () => {
      await focusDashboard();
      await herdr!.closePane(options.terminalPaneId);
    });

  let active:
    | {
        readonly target: HerdrTerminalTarget;
        readonly unsubscribe: () => void;
      }
    | undefined;

  const makeClient = (target: HerdrTerminalLaunchTarget) => {
    if (dependencies.makeClient) return dependencies.makeClient(target);
    let socketUrlAvailable = true;
    const runtime = buildTuiRuntime({
      origin: target.origin,
      bearerToken: "herdr-terminal-bridge",
      mintSocketUrl: async () => {
        if (!socketUrlAvailable) throw new Error("terminal bridge connection closed");
        socketUrlAvailable = false;
        return target.socketUrl;
      },
      logPath: options.logPath,
    });
    const client = makeTuiClient(runtime, target.origin);
    return { client, dispose: () => client.dispose() };
  };

  const connection = makeClient(options);

  const deactivate = () => {
    const previous = active;
    active = undefined;
    if (!previous) return;
    previous.unsubscribe();
  };

  const activate = (target: HerdrTerminalTarget) => {
    deactivate();
    const threadId = target.threadId as ThreadId;
    const unsubscribe = connection.client.subscribeTerminal(
      {
        threadId,
        terminalId: target.terminalId,
        cwd: target.cwd,
        worktreePath: target.worktreePath,
        cols: cols(),
        rows: rows(),
      },
      (event) => {
        const output = terminalBridgeOutput(event);
        if (output) stdout.write(output);
      },
    );
    active = { target, unsubscribe };
  };

  let switching = Promise.resolve();
  const parser = createHerdrTerminalInputParser({
    onInput: (data) => {
      const current = active;
      if (!current || data.length === 0) return;
      void connection.client
        .terminalWrite(
          current.target.threadId as ThreadId,
          current.target.terminalId,
          data,
          "terminal",
        )
        .catch(() => {});
    },
    onSwitch: (target) => {
      switching = switching
        .then(() => {
          activate(target);
        })
        .catch((error) => {
          stdout.write(`\r\n[T3 terminal switch failed: ${String(error)}]\r\n`);
        });
    },
  });

  const onInput = (data: Buffer) => {
    routeHerdrTerminalShortcuts(data.toString("utf8"), {
      onInput: parser.push,
      onFocusDashboard: () => void focusDashboard().catch(() => {}),
      onCloseTerminal: () => void closeTerminal().catch(() => {}),
    });
  };
  const onResize = () => {
    const current = active;
    if (!current) return;
    void connection.client
      .terminalResize(
        current.target.threadId as ThreadId,
        current.target.terminalId,
        cols(),
        rows(),
      )
      .catch(() => {});
  };

  let finish = () => {};
  const onSignal = () => finish();
  try {
    activate(options);
    await new Promise<void>((resolve) => {
      let settled = false;
      finish = () => {
        if (settled) return;
        settled = true;
        resolve();
      };
      stdin.setRawMode?.(true);
      stdin.resume();
      stdin.on("data", onInput);
      process.on("SIGWINCH", onResize);
      process.once("SIGINT", onSignal);
      process.once("SIGTERM", onSignal);
      process.once("SIGHUP", onSignal);
    });
    parser.flush();
    await switching;
  } finally {
    stdin.off("data", onInput);
    process.off("SIGWINCH", onResize);
    process.off("SIGINT", onSignal);
    process.off("SIGTERM", onSignal);
    process.off("SIGHUP", onSignal);
    stdin.setRawMode?.(false);
    deactivate();
    await connection.dispose().catch(() => {});
    herdr?.dispose();
  }
}
