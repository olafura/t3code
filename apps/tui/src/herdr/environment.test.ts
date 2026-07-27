import { describe, expect, it } from "bun:test";

import { tuiHostFromEnvironment } from "./environment.ts";

describe("tuiHostFromEnvironment", () => {
  it("defaults to standalone mode", () => {
    expect(tuiHostFromEnvironment({}, "http://localhost").kind).toBe("standalone");
  });

  it("requires the Herdr pane context", () => {
    expect(() =>
      tuiHostFromEnvironment({ T3_TUI_HOST: "herdr", HERDR_SOCKET_PATH: "/tmp/herdr.sock" }, "env"),
    ).toThrow("HERDR_PANE_ID");
  });

  it("creates a Herdr host from injected plugin context", () => {
    const host = tuiHostFromEnvironment(
      {
        T3_TUI_HOST: "herdr",
        HERDR_SOCKET_PATH: "/tmp/herdr.sock",
        HERDR_PANE_ID: "w1:p2",
        HERDR_WORKSPACE_ID: "w1",
        HERDR_PLUGIN_ID: "dev.t3code",
        HERDR_PLUGIN_STATE_DIR: "/tmp/t3-herdr",
      },
      "http://localhost:13773",
    );
    expect(host.kind).toBe("herdr");
    if (host.kind === "herdr") host.dispose();
  });
});
