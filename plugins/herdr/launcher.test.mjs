import { describe, expect, it } from "bun:test";

import { launcherCommand, isMainModule, resolveWorkspaceCwd } from "./launcher.mjs";

describe("Herdr plugin launcher", () => {
  it("starts a linked checkout directly in Herdr host mode", () => {
    expect(
      launcherCommand("dashboard", {
        root: "/checkout",
        fileExists: (path) => path === "/checkout/apps/server/src/bin.ts",
      }),
    ).toEqual([
      process.execPath,
      [
        "/checkout/apps/server/src/bin.ts",
        "tui",
        "--tui-host",
        "herdr",
        "--dev-url",
        "http://localhost:5733",
      ],
    ]);
  });

  it("allows a linked checkout to target a different development server", () => {
    expect(
      launcherCommand("dashboard", {
        devUrl: "http://localhost:9000",
        root: "/checkout",
        fileExists: () => true,
      }),
    ).toEqual([
      process.execPath,
      [
        "/checkout/apps/server/src/bin.ts",
        "tui",
        "--tui-host",
        "herdr",
        "--dev-url",
        "http://localhost:9000",
      ],
    ]);
  });

  it("falls back to an installed t3 executable outside a source checkout", () => {
    expect(
      launcherCommand("server", {
        root: "/plugin",
        fileExists: () => false,
      }),
    ).toEqual(["t3", ["serve", "--no-browser"]]);
  });

  it("honors an explicit t3 executable", () => {
    expect(
      launcherCommand("dashboard", {
        executable: "/opt/t3/bin/t3",
        fileExists: () => true,
      }),
    ).toEqual(["/opt/t3/bin/t3", ["tui", "--tui-host", "herdr"]]);
  });

  it("recognizes Herdr's relative launcher path as the main module", () => {
    expect(isMainModule("launcher.mjs", import.meta.dirname)).toBe(true);
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
