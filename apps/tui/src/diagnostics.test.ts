import { describe, expect, it } from "bun:test";
import * as NodeFS from "node:fs";
import * as NodeOS from "node:os";
import * as NodePath from "node:path";

import { captureTuiConsole } from "./diagnostics.ts";

describe("TUI diagnostics", () => {
  it("saves render error stacks and warnings while preserving console output", () => {
    const directory = NodeFS.mkdtempSync(NodePath.join(NodeOS.tmpdir(), "t3-tui-log-"));
    const path = NodePath.join(directory, "tui.log");
    const displayed: unknown[][] = [];
    const target = {
      error: (...args: unknown[]) => {
        displayed.push(args);
      },
      warn: (...args: unknown[]) => {
        displayed.push(args);
      },
    };
    const originalError = target.error;
    const restore = captureTuiConsole(path, target);
    try {
      const error = new Error("render failed");
      target.error(error);
      target.warn("connection %s", "closed");
      const log = NodeFS.readFileSync(path, "utf8");
      expect(log).toContain(error.stack!);
      expect(log).toContain("warn: connection closed");
      expect(displayed).toEqual([[error], ["connection %s", "closed"]]);
      restore();
      expect(target.error).toBe(originalError);
    } finally {
      restore();
      NodeFS.rmSync(directory, { recursive: true, force: true });
    }
  });

  it("still displays errors if writing the file fails", () => {
    const displayed: unknown[][] = [];
    const target = {
      error: (...args: unknown[]) => {
        displayed.push(args);
      },
      warn: () => {},
    };
    const restore = captureTuiConsole("/dev/null/tui.log", target);
    try {
      target.error("visible error");
      expect(displayed).toEqual([["visible error"]]);
    } finally {
      restore();
    }
  });
});
