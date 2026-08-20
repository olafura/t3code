import { describe, expect, it } from "bun:test";
import { ImageRenderable } from "@opentui/core";
import { testRender } from "@opentui/react/test-utils";
import * as React from "react";

import { Image } from "./react.ts";

describe("Image", () => {
  it("mounts OpenTUI's native image renderable at the requested size", async () => {
    const t = await testRender(
      <Image
        id="preview"
        data={new Uint8Array([255, 64, 32, 255])}
        imageWidth={1}
        imageHeight={1}
        columns={3}
        rows={2}
      />,
      { width: 20, height: 8 },
    );
    await React.act(async () => {});
    await t.renderOnce();

    const image = t.renderer.root.findDescendantById("preview");
    expect(image).toBeInstanceOf(ImageRenderable);
    expect(image?.width).toBe(3);
    expect(image?.height).toBe(2);
    await React.act(async () => t.renderer.destroy());
  });

  it("preserves pixel aspect ratio when only a column limit is supplied", async () => {
    const t = await testRender(
      <Image
        id="preview"
        data={new Uint8Array(100 * 100 * 4)}
        imageWidth={100}
        imageHeight={100}
        columns={10}
        fallbackCellWidth={10}
        fallbackCellHeight={20}
      />,
      { width: 80, height: 24 },
    );
    await React.act(async () => {});
    await t.renderOnce();

    const image = t.renderer.root.findDescendantById("preview");
    expect(image?.width).toBe(10);
    expect(image?.height).toBe(5);
    await React.act(async () => t.renderer.destroy());
  });
});
