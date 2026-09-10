import { describe, expect, it } from "vite-plus/test";
import { ShellRightPanelState } from "@t3tools/contracts/shell";
import * as Schema from "effect/Schema";

import type { RightPanelSurface } from "../rightPanelStore";
import { buildEmbedPath, buildShellRightPanelState } from "./shellRightPanelState";

const decodeRightPanelState = Schema.decodeUnknownSync(ShellRightPanelState);

describe("buildShellRightPanelState", () => {
  it("projects surfaces with titles and the embed path", () => {
    const surfaces: RightPanelSurface[] = [
      { id: "diff", kind: "diff" },
      { id: "pull-requests", kind: "pull-requests" },
      {
        id: "terminal:1",
        kind: "terminal",
        resourceId: "1",
        terminalIds: ["t1"],
        activeTerminalId: "t1",
      },
      {
        id: "file:src/a.ts",
        kind: "file",
        relativePath: "src/a.ts",
        revealLine: null,
        revealRequestId: 0,
      },
    ];
    const state = buildShellRightPanelState({
      threadKey: "env:thread",
      environmentId: "env",
      threadId: "thread",
      isOpen: true,
      activeSurfaceId: "terminal:1",
      surfaces,
      titleFor: (surface) => (surface.kind === "file" ? surface.relativePath : surface.kind),
      canAdd: { diff: true, files: true, terminal: true, pullRequest: false, agents: true },
    });
    expect(state.surfaces).toEqual([
      { id: "diff", kind: "diff", title: "diff" },
      { id: "pull-requests", kind: "pull-requests", title: "pull-requests" },
      { id: "terminal:1", kind: "terminal", title: "terminal" },
      { id: "file:src/a.ts", kind: "file", title: "src/a.ts" },
    ]);
    expect(state.activeSurfaceId).toBe("terminal:1");
    expect(decodeRightPanelState(state)).toEqual(state);
    expect(state.embedPath).toBe("/embed/env/thread");
  });

  it("encodes path segments", () => {
    expect(buildEmbedPath("env/1", "thread 2")).toBe("/embed/env%2F1/thread%202");
  });
});
