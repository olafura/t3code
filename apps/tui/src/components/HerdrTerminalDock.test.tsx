import { describe, expect, it } from "bun:test";
import { testRender } from "@opentui/react/test-utils";
import * as React from "react";

import { HerdrTerminalDock } from "./HerdrTerminalDock.tsx";

describe("HerdrTerminalDock", () => {
  it("shows explicit terminal tabs and dispatches switch and new-terminal clicks", async () => {
    const selected: string[] = [];
    let newTerminals = 0;
    const setup = await testRender(
      <HerdrTerminalDock
        title="Update UI Theme and Check Regressions"
        width={120}
        tabIds={["term-1", "term-2"]}
        activeTabId="term-1"
        onSelectTab={(id) => selected.push(id)}
        onNewTab={() => {
          newTerminals += 1;
        }}
        onCloseTab={() => {}}
      />,
      { width: 120, height: 5 },
    );

    await setup.renderOnce();
    await setup.flush();
    const frame = setup.captureCharFrame();

    expect(frame).toContain("▸ Terminal 1");
    expect(frame).toContain("Terminal 2");
    expect(frame).toContain("+ New");

    const clickLabel = async (label: string) => {
      const lines = setup.captureCharFrame().split("\n");
      const row = lines.findIndex((line) => line.includes(label));
      const column = row < 0 ? -1 : (lines[row]?.indexOf(label) ?? -1);
      expect(row).toBeGreaterThanOrEqual(0);
      expect(column).toBeGreaterThanOrEqual(0);
      await setup.mockMouse.click(column, row);
      await setup.flush();
    };

    await clickLabel("Terminal 2");
    await clickLabel("+ New");
    expect(selected).toEqual(["term-2"]);
    expect(newTerminals).toBe(1);
    setup.renderer.destroy();
  });
});
