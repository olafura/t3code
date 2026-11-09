import * as NodeServices from "@effect/platform-node/NodeServices";
import { assert, it } from "@effect/vitest";
import { HostProcessArchitecture, HostProcessPlatform } from "@t3tools/shared/hostProcess";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import { vi } from "vite-plus/test";

import { PtyAdapter, PtySpawnError } from "../Services/PTY.ts";
import { makeLayer } from "./NodePTY.ts";

const spawn = vi.fn(() => ({
  pid: 42,
  write: vi.fn(),
  resize: vi.fn(),
  kill: vi.fn(),
  onData: vi.fn(() => ({ dispose: vi.fn() })),
  onExit: vi.fn(() => ({ dispose: vi.fn() })),
}));

const makeTestLayer = (
  loadNodePty = async () => ({ spawn }) as unknown as typeof import("node-pty"),
) =>
  makeLayer(loadNodePty).pipe(
    Layer.provide(
      Layer.mergeAll(
        NodeServices.layer,
        Layer.succeed(HostProcessPlatform, "win32"),
        Layer.succeed(HostProcessArchitecture, "x64"),
      ),
    ),
  );

it.effect("spawns through the public adapter with the provided host references", () =>
  Effect.gen(function* () {
    spawn.mockClear();
    const adapter = yield* PtyAdapter;
    const process = yield* adapter.spawn({
      shell: "powershell.exe",
      args: ["-NoLogo"],
      cwd: "C:\\workspace",
      cols: 120,
      rows: 40,
      env: {},
    });

    assert.equal(process.pid, 42);
    assert.equal(spawn.mock.calls.length, 1);
    assert.deepEqual(spawn.mock.calls[0], [
      "powershell.exe",
      ["-NoLogo"],
      {
        cwd: "C:\\workspace",
        cols: 120,
        rows: 40,
        env: {},
        name: "xterm-color",
      },
    ]);
  }).pipe(Effect.provide(makeTestLayer())),
);

it.effect("reports node-pty native load failures from spawn instead of layer startup", () =>
  Effect.gen(function* () {
    const adapter = yield* PtyAdapter;
    const result = yield* Effect.result(
      adapter.spawn({
        shell: "powershell.exe",
        cwd: "C:\\workspace",
        cols: 120,
        rows: 40,
        env: {},
      }),
    );

    assert.equal(result._tag, "Failure");
    if (result._tag !== "Failure") {
      throw new Error("Expected node-pty load failure");
    }
    const failure = result.failure;
    assert.instanceOf(failure, PtySpawnError);
    assert.equal(failure.adapter, "node-pty");
    assert.match(failure.message, /node-pty native module is unavailable for win32-x64/);
  }).pipe(
    Effect.provide(
      makeTestLayer(async () => {
        throw new Error("Failed to load native module: pty.node");
      }),
    ),
  ),
);
