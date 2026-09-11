// @effect-diagnostics nodeBuiltinImport:off - Subprocess tests inspect temporary log files.
import { describe, expect, it } from "bun:test";
import * as NodeFS from "node:fs";
import * as NodeOS from "node:os";
import * as NodePath from "node:path";
import { HostProcessPlatform } from "@t3tools/shared/hostProcess";

import { buildSocketUrl, buildTuiChildEnvironment, runBunTui } from "./tui.ts";
import {
  ORCHESTRATION_PROTOCOL_QUERY_PARAM,
  ORCHESTRATION_PROTOCOL_VERSION,
} from "@t3tools/contracts";

describe("TUI WebSocket handshake", () => {
  it.each([
    ["http://127.0.0.1:13773", "ws:"],
    ["https://host.example", "wss:"],
  ])("announces the current protocol when connecting to %s", (origin, protocol) => {
    const url = new URL(buildSocketUrl(origin, "ticket+with/special=characters"));
    expect(url.protocol).toBe(protocol);
    expect(url.pathname).toBe("/ws");
    expect(url.searchParams.get("wsTicket")).toBe("ticket+with/special=characters");
    expect(url.searchParams.get(ORCHESTRATION_PROTOCOL_QUERY_PARAM)).toBe(
      String(ORCHESTRATION_PROTOCOL_VERSION),
    );
  });
});

describe("buildTuiChildEnvironment", () => {
  it("preserves the Herdr plugin context and selects Herdr host mode", () => {
    const environment = buildTuiChildEnvironment({
      environment: {
        HERDR_SOCKET_PATH: "/tmp/herdr.sock",
        HERDR_PANE_ID: "w1:p1",
        KEEP_ME: "yes",
      },
      origin: "http://127.0.0.1:13773",
      bearerToken: "secret",
      logPath: "/tmp/t3-tui.log",
      host: "herdr",
    });
    expect(environment).toMatchObject({
      HERDR_SOCKET_PATH: "/tmp/herdr.sock",
      HERDR_PANE_ID: "w1:p1",
      KEEP_ME: "yes",
      T3_TUI_HOST: "herdr",
      T3_TUI_ORIGIN: "http://127.0.0.1:13773",
      T3_TUI_BEARER: "secret",
    });
  });
});

describe("TUI subprocess diagnostics", () => {
  it.skipIf(HostProcessPlatform.defaultValue() === "win32")(
    "saves startup crashes and returns the child's failing exit status",
    async () => {
      const directory = NodeFS.mkdtempSync(NodePath.join(NodeOS.tmpdir(), "t3-tui-child-"));
      const executable = NodePath.join(directory, "fake-bun");
      const logPath = NodePath.join(directory, "tui.log");
      const previous = process.env.T3_TUI_BUN;
      NodeFS.writeFileSync(executable, '#!/bin/sh\nprintf "startup crash\\n" >&2\nexit 17\n', {
        mode: 0o700,
      });
      process.env.T3_TUI_BUN = executable;
      try {
        const code = await runBunTui({
          origin: "http://127.0.0.1:13773",
          bearerToken: "test-secret",
          logPath,
          host: "standalone",
          mintSocketUrl: async () => {
            throw new Error("must not connect");
          },
        });
        expect(code).toBe(17);
        const log = NodeFS.readFileSync(logPath, "utf8");
        expect(log).toContain("startup crash");
        expect(log).toContain("TUI exited: code=17");
        expect(log).not.toContain("test-secret");
      } finally {
        if (previous === undefined) delete process.env.T3_TUI_BUN;
        else process.env.T3_TUI_BUN = previous;
        NodeFS.rmSync(directory, { recursive: true, force: true });
      }
    },
  );
});
