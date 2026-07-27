import { describe, expect, it } from "bun:test";
import { testRender } from "@opentui/react/test-utils";
import * as React from "react";

import { HerdrTerminalDock } from "./HerdrTerminalDock.tsx";

describe("HerdrTerminalDock", () => {
  it("shows explicit terminal tabs with the active terminal distinguished", async () => {
    const setup = await testRender(
      <HerdrTerminalDock
        title="Update UI Theme and Check Regressions"
        width={120}
        tabIds={["term-1", "term-2"]}
        activeTabId="term-1"
        onSelectTab={() => {}}
        onNewTab={() => {}}
        onCloseTab={() => {}}
      />,
      { width: 124, height: 5 },
    );

    await setup.renderOnce();
    const frame = setup.captureCharFrame();
    setup.renderer.destroy();

    expect(frame).toContain("▸ Terminal 1");
    expect(frame).toContain("Terminal 2");
    expect(frame).toContain("+ New");
  });
});
