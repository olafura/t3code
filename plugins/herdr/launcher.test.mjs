import { describe, expect, it } from "bun:test";

import { launcherCommand, resolveWorkspaceCwd } from "./launcher.mjs";

describe("Herdr plugin launcher", () => {
  it("starts the hybrid TUI in Herdr host mode", () => {
    expect(launcherCommand("dashboard")).toEqual(["t3", ["tui", "--tui-host", "herdr"]]);
  });

  it("starts the server in its own pane", () => {
    expect(launcherCommand("server")).toEqual(["t3", ["serve", "--no-browser"]]);
  });

  it("uses the workspace worktree from the plugin context", () => {
    expect(
      resolveWorkspaceCwd({
        workspace: { worktree: { checkout_path: "/worktrees/t3-plugin" } },
        pane: { cwd: "/repo" },
      }),
    ).toBe("/worktrees/t3-plugin");
  });
});
