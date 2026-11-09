import { createRequire } from "node:module";

import * as Effect from "effect/Effect";
import * as FileSystem from "effect/FileSystem";
import * as Layer from "effect/Layer";
import * as Path from "effect/Path";
import { HostProcessArchitecture, HostProcessPlatform } from "@t3tools/shared/hostProcess";
import { PtyAdapter } from "../Services/PTY.ts";
import {
  PtySpawnError,
  type PtyAdapterShape,
  type PtyExitEvent,
  type PtyProcess,
} from "../Services/PTY.ts";

let didEnsureSpawnHelperExecutable = false;

type NodePtyModule = typeof import("node-pty");
type LoadNodePty = () => Promise<NodePtyModule>;

function makeNodePtyLoadError(
  cause: unknown,
  platform: string,
  architecture: string,
): PtySpawnError {
  const detail = cause instanceof Error ? ` ${cause.message}` : "";
  return new PtySpawnError({
    adapter: "node-pty",
    message:
      `node-pty native module is unavailable for ${platform}-${architecture}. ` +
      "Run `pnpm rebuild node-pty` or reinstall dependencies with build scripts enabled, then restart T3 Code." +
      detail,
    cause,
  });
}

const resolveNodePtySpawnHelperPath = Effect.gen(function* () {
  const requireForNodePty = createRequire(import.meta.url);
  const path = yield* Path.Path;
  const fs = yield* FileSystem.FileSystem;
  const platform = yield* HostProcessPlatform;
  const architecture = yield* HostProcessArchitecture;

  const packageJsonPath = requireForNodePty.resolve("node-pty/package.json");
  const packageDir = path.dirname(packageJsonPath);
  const candidates = [
    path.join(packageDir, "build", "Release", "spawn-helper"),
    path.join(packageDir, "build", "Debug", "spawn-helper"),
    path.join(packageDir, "prebuilds", `${platform}-${architecture}`, "spawn-helper"),
  ];

  for (const candidate of candidates) {
    if (yield* fs.exists(candidate)) {
      return candidate;
    }
  }
  return null;
}).pipe(Effect.orElseSucceed(() => null));

const ensureNodePtySpawnHelperExecutable = Effect.fn(function* () {
  const fs = yield* FileSystem.FileSystem;
  const platform = yield* HostProcessPlatform;
  if (platform === "win32") return;
  if (didEnsureSpawnHelperExecutable) return;

  const helperPath = yield* resolveNodePtySpawnHelperPath;
  if (!helperPath) return;
  didEnsureSpawnHelperExecutable = true;

  if (!(yield* fs.exists(helperPath))) {
    return;
  }

  // Best-effort: avoid FileSystem.stat in packaged mode where some fs metadata can be missing.
  yield* fs.chmod(helperPath, 0o755).pipe(Effect.orElseSucceed(() => undefined));
});

class NodePtyProcess implements PtyProcess {
  private readonly process: import("node-pty").IPty;

  constructor(process: import("node-pty").IPty) {
    this.process = process;
  }

  get pid(): number {
    return this.process.pid;
  }

  write(data: string): void {
    this.process.write(data);
  }

  resize(cols: number, rows: number): void {
    this.process.resize(cols, rows);
  }

  kill(signal?: string): void {
    this.process.kill(signal);
  }

  onData(callback: (data: string) => void): () => void {
    const disposable = this.process.onData(callback);
    return () => {
      disposable.dispose();
    };
  }

  onExit(callback: (event: PtyExitEvent) => void): () => void {
    const disposable = this.process.onExit((event) => {
      callback({
        exitCode: event.exitCode,
        signal: event.signal ?? null,
      });
    });
    return () => {
      disposable.dispose();
    };
  }
}

export function makeLayer(loadNodePty: LoadNodePty = () => import("node-pty")) {
  return Layer.effect(
    PtyAdapter,
    Effect.gen(function* () {
      const fs = yield* FileSystem.FileSystem;
      const path = yield* Path.Path;
      const platform = yield* HostProcessPlatform;
      const architecture = yield* HostProcessArchitecture;

      const loadNodePtyCached = yield* Effect.cached(
        Effect.tryPromise({
          try: loadNodePty,
          catch: (cause) => makeNodePtyLoadError(cause, platform, architecture),
        }),
      );

      const ensureNodePtySpawnHelperExecutableCached = yield* Effect.cached(
        ensureNodePtySpawnHelperExecutable().pipe(
          Effect.provideService(FileSystem.FileSystem, fs),
          Effect.provideService(Path.Path, path),
          Effect.provideService(HostProcessPlatform, platform),
          Effect.provideService(HostProcessArchitecture, architecture),
          Effect.orElseSucceed(() => undefined),
        ),
      );

      return {
        spawn: Effect.fn(function* (input) {
          const nodePty = yield* loadNodePtyCached;
          yield* ensureNodePtySpawnHelperExecutableCached;
          const ptyProcess = yield* Effect.try({
            try: () =>
              nodePty.spawn(input.shell, input.args ?? [], {
                cwd: input.cwd,
                cols: input.cols,
                rows: input.rows,
                env: input.env,
                name: platform === "win32" ? "xterm-color" : "xterm-256color",
              }),
            catch: (cause) =>
              new PtySpawnError({
                adapter: "node-pty",
                message: cause instanceof Error ? cause.message : "Failed to spawn PTY process",
                cause,
              }),
          });
          return new NodePtyProcess(ptyProcess);
        }),
      } satisfies PtyAdapterShape;
    }),
  );
}

export const layer = makeLayer();
