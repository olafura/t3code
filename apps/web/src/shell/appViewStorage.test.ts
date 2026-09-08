import { scopeThreadRef, scopedThreadKey } from "@t3tools/client-runtime/environment";
import { EnvironmentId, ThreadId } from "@t3tools/contracts";
import { afterEach, expect, it, vi } from "vite-plus/test";

import { appViewStorageKey } from "./appViewStorage";

afterEach(() => {
  vi.useRealTimers();
  vi.unstubAllGlobals();
  vi.resetModules();
});

it("leaves ordinary browsers and coordinated primary/embed clients on existing keys", () => {
  expect(appViewStorageKey("t3code:composer-drafts:v1")).toBe("t3code:composer-drafts:v1");
  for (const surfaceId of ["primary", "panel"]) {
    vi.stubGlobal("window", { t3Shell: { surfaceId } });
    expect(appViewStorageKey("t3code:composer-drafts:v1")).toBe("t3code:composer-drafts:v1");
  }
});

it("restores each independent client's actual draft and panel stores without overwriting another", async () => {
  const saved = new Map<string, string>([["pairing-fixture", "shared-session"]]);
  const storage = {
    getItem: (key: string) => saved.get(key) ?? null,
    setItem: (key: string, value: string) => saved.set(key, value),
    removeItem: (key: string) => saved.delete(key),
  };
  const loadClient = async (id?: string) => {
    vi.stubGlobal(
      "window",
      Object.assign(new EventTarget(), {
        localStorage: storage,
        __t3AppViewStorageId: id,
      }),
    );
    vi.stubGlobal("localStorage", storage);
    vi.resetModules();
    const [composer, panel, terminal, diff] = await Promise.all([
      import("../composerDraftStore"),
      import("../rightPanelStore"),
      import("../terminalUiStateStore"),
      import("../diffPanelStore"),
    ]);
    return { composer, panel, terminal, diff };
  };

  const first = await loadClient("planning");
  const second = await loadClient("implementation");
  const primary = await loadClient();
  const a = scopeThreadRef(EnvironmentId.make("local"), ThreadId.make("thread-a"));
  const b = scopeThreadRef(EnvironmentId.make("remote"), ThreadId.make("thread-b"));
  const write = (client: typeof first, ref: typeof a, label: string) => {
    client.composer.useComposerDraftStore.getState().setPrompt(ref, label);
    client.panel.useRightPanelStore.getState().openFile(ref, `${label}.ts`);
    client.terminal.useTerminalUiStateStore.getState().setTerminalHeight(ref, 350);
    client.diff.useDiffPanelStore.getState().selectBranchBaseRef(ref, label);
  };
  vi.useFakeTimers();
  write(first, a, "planning draft");
  await vi.advanceTimersByTimeAsync(300);
  write(second, b, "implementation draft");
  await vi.advanceTimersByTimeAsync(300);
  write(primary, a, "primary draft");
  await vi.advanceTimersByTimeAsync(300);
  vi.useRealTimers();

  for (const [id, ref, absent, label] of [
    ["planning", a, b, "planning draft"],
    ["implementation", b, a, "implementation draft"],
    [undefined, a, b, "primary draft"],
  ] as const) {
    const restored = await loadClient(id);
    const key = scopedThreadKey(ref);
    const absentKey = scopedThreadKey(absent);
    expect(restored.composer.useComposerDraftStore.getState().getComposerDraft(ref)?.prompt).toBe(
      label,
    );
    expect(
      restored.composer.useComposerDraftStore.getState().draftsByThreadKey[absentKey],
    ).toBeUndefined();
    expect(restored.panel.useRightPanelStore.getState().byThreadKey[key]?.surfaces).toEqual([
      expect.objectContaining({ kind: "file", relativePath: `${label}.ts` }),
    ]);
    expect(restored.panel.useRightPanelStore.getState().byThreadKey[absentKey]).toBeUndefined();
    expect(
      restored.terminal.useTerminalUiStateStore.getState().terminalUiStateByThreadKey[key]
        ?.terminalHeight,
    ).toBe(350);
    expect(
      restored.terminal.useTerminalUiStateStore.getState().terminalUiStateByThreadKey[absentKey],
    ).toBeUndefined();
    expect(restored.diff.useDiffPanelStore.getState().byThreadKey[key]).toEqual({
      kind: "branch",
      baseRef: label,
    });
    expect(restored.diff.useDiffPanelStore.getState().byThreadKey[absentKey]).toBeUndefined();
  }
  expect(storage.getItem("pairing-fixture")).toBe("shared-session");
});
