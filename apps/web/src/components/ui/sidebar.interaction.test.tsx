import { act, create, type ReactTestRenderer } from "react-test-renderer";
import { afterEach, beforeEach, describe, expect, it, vi } from "vite-plus/test";

import { SidebarProvider, useSidebar } from "./sidebar";

const viewport = vi.hoisted(() => ({ mobile: true }));
vi.mock("~/hooks/useMediaQuery", () => ({ useIsMobile: () => viewport.mobile }));

function SidebarProbe() {
  const { open, openMobile, toggleSidebar } = useSidebar();
  return (
    <>
      <button onClick={toggleSidebar}>Toggle sidebar</button>
      <output>{`${open}:${openMobile}`}</output>
    </>
  );
}

describe("sidebar state ownership", () => {
  let renderer: ReactTestRenderer;

  beforeEach(() => {
    viewport.mobile = true;
    vi.stubGlobal("IS_REACT_ACT_ENVIRONMENT", true);
    vi.stubGlobal("cookieStore", { set: vi.fn().mockResolvedValue(undefined) });
  });

  afterEach(async () => {
    if (renderer) await act(async () => renderer.unmount());
    vi.unstubAllGlobals();
  });

  it("keeps native sidebar toggles on the same state across viewport sizes", async () => {
    const view = () => (
      <SidebarProvider responsive={false}>
        <SidebarProbe />
      </SidebarProvider>
    );
    await act(async () => {
      renderer = create(view());
    });
    await act(async () => renderer.root.findByType("button").props.onClick());
    expect(renderer.root.findByType("output").children).toEqual(["false:false"]);

    viewport.mobile = false;
    await act(async () => renderer.update(view()));
    expect(renderer.root.findByType("output").children).toEqual(["false:false"]);
    await act(async () => renderer.root.findByType("button").props.onClick());
    expect(renderer.root.findByType("output").children).toEqual(["true:false"]);

    viewport.mobile = true;
    await act(async () => renderer.update(view()));
    await act(async () => renderer.root.findByType("button").props.onClick());
    expect(renderer.root.findByType("output").children).toEqual(["false:false"]);
  });

  it("retains the separate mobile drawer for responsive web sidebars", async () => {
    await act(async () => {
      renderer = create(
        <SidebarProvider>
          <SidebarProbe />
        </SidebarProvider>,
      );
    });
    await act(async () => renderer.root.findByType("button").props.onClick());
    expect(renderer.root.findByType("output").children).toEqual(["true:true"]);
    await act(async () => renderer.root.findByType("button").props.onClick());
    expect(renderer.root.findByType("output").children).toEqual(["true:false"]);
  });
});
