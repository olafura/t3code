import { describe, expect, it } from "bun:test";

import { buildTuiChildEnvironment } from "./tui.ts";

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
