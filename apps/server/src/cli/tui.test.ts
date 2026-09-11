import { describe, expect, it } from "bun:test";

import { buildSocketUrl, buildTuiChildEnvironment } from "./tui.ts";
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
