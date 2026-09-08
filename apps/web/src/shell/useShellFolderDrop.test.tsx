import { EnvironmentId } from "@t3tools/contracts";
import { act, useLayoutEffect } from "react";
import { create, type ReactTestRenderer } from "react-test-renderer";
import { afterEach, describe, expect, it, vi } from "vite-plus/test";
import { useShellFolderDrop, type ShellFolderOpenRequest } from "./useShellFolderDrop";

let renderer: ReactTestRenderer | null = null;
afterEach(async () => {
  await act(() => renderer?.unmount());
  renderer = null;
  vi.unstubAllGlobals();
});

async function setup(options: { hostname?: string; connected?: boolean } = {}) {
  let drop!: (path: string) => Promise<void>;
  const open = vi.fn<(input: ShellFolderOpenRequest) => Promise<void>>().mockResolvedValue();
  const onError = vi.fn();
  vi.stubGlobal("IS_REACT_ACT_ENVIRONMENT", true);
  vi.stubGlobal("window", {
    location: { hostname: options.hostname ?? "localhost" },
  });
  function Harness() {
    const openDroppedFolder = useShellFolderDrop({
      primaryEnvironmentId: EnvironmentId.make("primary"),
      platform: "Linux",
      connected: options.connected ?? true,
      open,
      onError,
    });
    useLayoutEffect(() => {
      drop = openDroppedFolder;
    }, [openDroppedFolder]);
    return null;
  }
  await act(() => {
    renderer = create(<Harness />);
  });
  return {
    open,
    onError,
    drop: (path: string) => {
      void drop(path);
    },
  };
}

describe("native folder drops", () => {
  it("serializes repeated drops and permits retry after a rejected operation", async () => {
    const { open, onError, drop } = await setup();
    let reject!: (error: Error) => void;
    open.mockImplementationOnce(
      () =>
        new Promise((_resolve, rejectPromise) => {
          reject = rejectPromise;
        }),
    );
    await act(() => {
      drop("/repo");
      drop("/repo");
    });
    expect(open).toHaveBeenCalledExactlyOnceWith({
      environmentId: "primary",
      rawCwd: "/repo",
      platform: "Linux",
      currentProjectCwd: null,
      createWorkspaceRootIfMissing: false,
    });
    await act(() => reject(new Error("Unavailable")));
    expect(onError).toHaveBeenCalledOnce();
    await act(() => drop("/repo"));
    expect(open).toHaveBeenCalledTimes(2);
  });

  it.each([
    { hostname: "remote.example", connected: true },
    { hostname: "localhost", connected: false },
  ])("does not register paths for an unavailable or remote host: %s", async (options) => {
    const { open, onError, drop } = await setup(options);
    await act(() => drop("/repo"));
    expect(open).not.toHaveBeenCalled();
    expect(onError).toHaveBeenCalledOnce();
  });

  it.each(["relative/repo", "../repo", "", "/repo\0other"])(
    "rejects ambiguous path %s",
    async (path) => {
      const { open, onError, drop } = await setup();
      await act(() => drop(path));
      expect(open).not.toHaveBeenCalled();
      expect(onError).toHaveBeenCalledOnce();
    },
  );
});
