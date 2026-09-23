import {
  FilesystemBrowseError,
  GitCommandError,
  OrchestrationGetFullThreadDiffError,
  OrchestrationGetTurnDiffError,
  ProjectMutationError,
  ReviewDiffPreviewError,
  OrchestrationV2DispatchCommandError,
  OrchestrationV2ThreadLaunchError,
  ORCHESTRATION_V2_WS_METHODS,
  ServerConfig,
  TerminalError,
  TerminalSessionLookupError,
  ThreadId,
  WS_METHODS,
  WsRpcGroup,
} from "@t3tools/contracts";
import * as Cause from "effect/Cause";
import * as DateTime from "effect/DateTime";
import * as Deferred from "effect/Deferred";
import * as Effect from "effect/Effect";
import * as Option from "effect/Option";
import * as Queue from "effect/Queue";
import * as Schema from "effect/Schema";
import * as Stream from "effect/Stream";
import * as RpcClientError from "effect/unstable/rpc/RpcClientError";
import * as RpcSchema from "effect/unstable/rpc/RpcSchema";
import type * as Scope from "effect/Scope";

import {
  ConnectionTransientError,
  type ConnectionAttemptError,
  type PreparedConnection,
} from "../connection/model.ts";
import type { RpcSession } from "../rpc/session.ts";
import type { WsRpcProtocolClient } from "../rpc/protocol.ts";
import { ClusterRpcError, ClusterSocket, type Shape, type ShapeFrame } from "./clusterSocket.ts";
import { ShellShapeFold, type ShellRow } from "./shellShape.ts";
import { ThreadShapeFold, type ShapeEvent, type ShapeRow } from "./threadShape.ts";

const decodeConfig = Schema.decodeUnknownSync(Schema.toCodecJson(ServerConfig));
const decodeTerminalError = Schema.decodeUnknownOption(TerminalError);

// A node's launch result leaves out the thread projection: nothing reads it, and the
// thread's stream shape already carries that state.
const UNDECODED_RESULTS: ReadonlySet<string> = new Set([ORCHESTRATION_V2_WS_METHODS.launchThread]);
const decodeReviewError = Schema.decodeUnknownOption(ReviewDiffPreviewError);

/**
 * Streams one shape's frames, folded into items, for as long as it is consumed. An
 * `error` frame fails the stream when `toError` is given.
 */
function shapeStream<A, E = never>(
  socket: ClusterSocket,
  shape: Shape,
  fold: (frame: ShapeFrame) => ReadonlyArray<A>,
  toError?: (frame: ShapeFrame) => E,
): Stream.Stream<A, E> {
  return Stream.callback<A, E>((queue) =>
    Effect.acquireRelease(
      Effect.sync(() =>
        socket.subscribe(shape, (frame) => {
          if (frame.t === "error" && toError !== undefined) {
            Queue.failCauseUnsafe(queue, Cause.fail(toError(frame)));
            return;
          }
          Queue.offerAllUnsafe(queue, fold(frame));
        }),
      ),
      (unsubscribe) => Effect.sync(unsubscribe),
    ),
  );
}

/** A node's terminal error, or a lookup error when it sent none that decodes. */
function terminalError(
  request: { readonly threadId: string; readonly terminalId?: string | undefined },
  detail: unknown,
): TerminalError {
  return decodeTerminalError(detail).pipe(
    Option.getOrElse(
      () =>
        new TerminalSessionLookupError({
          threadId: request.threadId,
          terminalId: request.terminalId ?? "",
        }),
    ),
  );
}

function unsupported(tag: string): RpcClientError.RpcClientError {
  return new RpcClientError.RpcClientError({
    reason: new RpcClientError.RpcClientDefect({
      message: `${tag} is not served by protocol-3 environments yet`,
      cause: null,
    }),
  });
}

/**
 * An `RpcSession` for one node of a protocol-3 cluster, carried over a shared
 * `ClusterSocket`. The shell and thread subscriptions and the server config are
 * served from shapes, so the environment state code runs unchanged; every other
 * RPC fails as unsupported until the node serves it.
 */
export function makeV3Session(input: {
  readonly socket: ClusterSocket;
  readonly environmentId: string;
}): Effect.Effect<RpcSession, ConnectionTransientError> {
  return Effect.gen(function* () {
    const { socket } = input;
    // The environment may live on another node of the cluster; its config reply
    // names the node that this session's shapes are addressed to.
    const reply = yield* Deferred.make<
      { readonly node: string; readonly config: ServerConfig },
      ConnectionTransientError
    >();
    const unsubscribeConfig = socket.subscribe(
      { type: "config", environment: input.environmentId },
      (frame) => {
        if (frame.t === "config")
          Deferred.doneUnsafe(
            reply,
            Effect.succeed({ node: String(frame.node), config: decodeConfig(frame.config) }),
          );
        if (frame.t === "error")
          Deferred.doneUnsafe(
            reply,
            Effect.fail(
              new ConnectionTransientError({
                reason: "remote-unavailable",
                detail: String(frame.reason),
              }),
            ),
          );
      },
    );
    const { node, config } = yield* Deferred.await(reply).pipe(
      Effect.ensuring(Effect.sync(unsubscribeConfig)),
    );
    const initialConfig = Effect.succeed(config);

    const shell = () => {
      const fold = new ShellShapeFold(node);
      return shapeStream(socket, { type: "shell" }, (frame) => {
        if (frame.t === "shell") return fold.shell(frame.rows as ReadonlyArray<ShellRow>);
        if (frame.t === "shell.rows")
          return fold.rows(
            String(frame.node),
            frame.rows as ReadonlyArray<readonly [string, string, Record<string, unknown>]>,
          );
        return [];
      });
    };

    const thread = (request: { readonly threadId: string }) => {
      const fold = new ThreadShapeFold(ThreadId.make(request.threadId));
      return shapeStream(socket, { type: "stream", node, stream: request.threadId }, (frame) => {
        switch (frame.t) {
          case "snapshot":
            return fold.snapshot({
              rows: frame.rows as ReadonlyArray<ShapeRow>,
              part: Number(frame.part),
              done: frame.done === true,
              offset: Number(frame.offset),
              at: typeof frame.at === "number" ? frame.at : null,
            });
          case "events":
            return fold.events(frame.events as ReadonlyArray<ShapeEvent>);
          case "live":
            return [{ kind: "synchronized" as const }];
          default:
            return [];
        }
      });
    };

    // Settings and config do not change on a node yet, so the stream is its snapshot.
    const serverConfig = () =>
      Stream.fromEffect(
        Effect.map(initialConfig, (value) => ({
          version: 1 as const,
          type: "snapshot" as const,
          config: value,
        })),
      );

    // A node never bootstraps a project from its cwd, so its welcome is complete at
    // once; the stream then stays open like the Node server's lifecycle stream.
    const serverLifecycle = () =>
      Stream.concat(
        Stream.make(
          {
            version: 1 as const,
            sequence: 0,
            type: "welcome" as const,
            payload: {
              environment: config.environment,
              cwd: config.cwd,
              projectName:
                config.cwd.split(/[\\/]/).findLast((part) => part.length > 0) ?? config.cwd,
              bootstrapStatus: "complete" as const,
            },
          },
          {
            version: 1 as const,
            sequence: 1,
            type: "ready" as const,
            payload: {
              at: DateTime.formatIso(DateTime.nowUnsafe()),
              environment: config.environment,
            },
          },
        ),
        Stream.never,
      );

    // RPCs run on the environment's node; a failure surfaces as the method's contract error.
    const forward =
      <R extends object, E>(
        tag: string,
        toError: (request: R, message: string, cause: unknown) => E,
      ) =>
      (request: R) => {
        // Results arrive as JSON; decode them as the Node RPC client would.
        const rpc = UNDECODED_RESULTS.has(tag) ? undefined : WsRpcGroup.requests.get(tag);
        const decode = (value: unknown): Effect.Effect<unknown, Schema.SchemaError> =>
          rpc === undefined
            ? Effect.succeed(value)
            : Schema.decodeUnknownEffect(
                Schema.toCodecJson(rpc.successSchema as Schema.Codec<unknown, unknown>),
              )(value);
        return Effect.tryPromise({
          try: () => socket.call(input.environmentId, tag, request),
          catch: (cause) =>
            toError(request, cause instanceof Error ? cause.message : String(cause), cause),
        }).pipe(
          Effect.flatMap((value) =>
            decode(value).pipe(
              Effect.mapError((cause) =>
                toError(request, `The node sent an invalid ${tag} result.`, cause),
              ),
            ),
          ),
        );
      };

    const dispatchCommand = forward(
      ORCHESTRATION_V2_WS_METHODS.dispatchCommand,
      (command: { readonly commandId: string; readonly type: string }, message) =>
        new OrchestrationV2DispatchCommandError({
          commandId: command.commandId as never,
          commandType: command.type as never,
          message,
        }),
    );

    const launchThread = forward(
      ORCHESTRATION_V2_WS_METHODS.launchThread,
      (request: { readonly commandId: string; readonly projectId: string }, message) =>
        new OrchestrationV2ThreadLaunchError({
          commandId: request.commandId as never,
          projectId: request.projectId as never,
          message,
        }),
    );

    const mutateProject = forward(
      WS_METHODS.projectsMutate,
      (mutation: { readonly commandId: string }, message) =>
        new ProjectMutationError({ commandId: mutation.commandId as never, message }),
    );

    const browse = forward(
      WS_METHODS.filesystemBrowse,
      (request: { readonly partialPath: string }, _message, cause) =>
        new FilesystemBrowseError({
          partialPath: request.partialPath as never,
          failure: "read_directory_failed",
          cause,
        }),
    );

    const getTurnDiff = forward(
      ORCHESTRATION_V2_WS_METHODS.getTurnDiff,
      (_request: object, message) => new OrchestrationGetTurnDiffError({ message }),
    );

    // Terminals live on the thread's node; attach and metadata are shapes there.
    type TerminalRequest = { readonly threadId: string; readonly terminalId?: string };
    const terminalCommand = (tag: string) =>
      forward(tag, (request: TerminalRequest, _message, cause) =>
        terminalError(request, cause instanceof ClusterRpcError ? cause.detail : undefined),
      );

    const terminalAttach = (request: TerminalRequest) =>
      shapeStream(
        socket,
        { type: "terminal", node, input: request },
        (frame) => (frame.t === "terminal" ? [frame.event] : []),
        (frame) => terminalError(request, frame.detail),
      );

    const terminalMetadata = () =>
      shapeStream(socket, { type: "terminals", node }, (frame) =>
        frame.t === "terminals" ? [frame.event] : [],
      );

    const reviewCommand = (tag: string) =>
      forward(tag, (request: { readonly cwd: string }, message, cause) =>
        decodeReviewError(cause instanceof ClusterRpcError ? cause.detail : undefined).pipe(
          Option.getOrElse(
            () =>
              new GitCommandError({
                operation: tag,
                command: "git",
                cwd: request.cwd,
                detail: message,
              }),
          ),
        ),
      );

    const getFullThreadDiff = forward(
      ORCHESTRATION_V2_WS_METHODS.getFullThreadDiff,
      (_request: object, message) => new OrchestrationGetFullThreadDiffError({ message }),
    );

    const served: Record<string, (request: never) => unknown> = {
      [WS_METHODS.projectsMutate]: mutateProject,
      [WS_METHODS.filesystemBrowse]: browse,
      [ORCHESTRATION_V2_WS_METHODS.dispatchCommand]: dispatchCommand,
      [ORCHESTRATION_V2_WS_METHODS.launchThread]: launchThread,
      [ORCHESTRATION_V2_WS_METHODS.getTurnDiff]: getTurnDiff,
      [ORCHESTRATION_V2_WS_METHODS.getFullThreadDiff]: getFullThreadDiff,
      [ORCHESTRATION_V2_WS_METHODS.subscribeShell]: shell,
      [ORCHESTRATION_V2_WS_METHODS.subscribeThread]: thread,
      [WS_METHODS.reviewGetDiffPreview]: reviewCommand(WS_METHODS.reviewGetDiffPreview),
      [WS_METHODS.reviewGetDiffFileContents]: reviewCommand(WS_METHODS.reviewGetDiffFileContents),
      [WS_METHODS.terminalAttach]: terminalAttach,
      [WS_METHODS.subscribeTerminalMetadata]: terminalMetadata,
      [WS_METHODS.terminalOpen]: terminalCommand(WS_METHODS.terminalOpen),
      [WS_METHODS.terminalWrite]: terminalCommand(WS_METHODS.terminalWrite),
      [WS_METHODS.terminalResize]: terminalCommand(WS_METHODS.terminalResize),
      [WS_METHODS.terminalClear]: terminalCommand(WS_METHODS.terminalClear),
      [WS_METHODS.terminalRestart]: terminalCommand(WS_METHODS.terminalRestart),
      [WS_METHODS.terminalClose]: terminalCommand(WS_METHODS.terminalClose),
      [WS_METHODS.serverGetConfig]: () => initialConfig,
      [WS_METHODS.serverProbe]: () => Effect.void,
      [WS_METHODS.subscribeServerConfig]: serverConfig,
      [WS_METHODS.subscribeServerLifecycle]: serverLifecycle,
    };

    // Every other method fails in the shape its callers expect: a stream or an effect.
    const client = new Proxy(served, {
      get(target, tag) {
        if (typeof tag !== "string") return undefined;
        const handler = target[tag];
        if (handler !== undefined) return handler;
        const rpc = WsRpcGroup.requests.get(tag);
        const streaming = rpc !== undefined && RpcSchema.isStreamSchema(rpc.successSchema);
        return () => (streaming ? Stream.fail(unsupported(tag)) : Effect.fail(unsupported(tag)));
      },
    }) as unknown as WsRpcProtocolClient;

    return {
      client,
      initialConfig,
      subscribeServerConfig: serverConfig,
      ready: Effect.void,
      probe: Effect.void,
      closed: Effect.never,
    } satisfies RpcSession;
  });
}

/**
 * Opens a protocol-3 session for a prepared connection. The socket URL carries a
 * single-use ticket, so the socket does not reconnect by itself: a drop fails
 * `closed`, and the environment supervisor reconnects with a fresh ticket.
 */
export const connectV3Session = (
  connection: PreparedConnection,
): Effect.Effect<RpcSession, ConnectionAttemptError, Scope.Scope> =>
  Effect.gen(function* () {
    const hello = yield* Deferred.make<string, ConnectionTransientError>();
    const closed = yield* Deferred.make<never, ConnectionTransientError>();
    const socket = yield* Effect.acquireRelease(
      Effect.sync(
        () =>
          new ClusterSocket({
            url: connection.socketUrl,
            reconnect: false,
            onStatus: (status) => {
              if (status.connected && status.node !== null) {
                Deferred.doneUnsafe(hello, Effect.succeed(status.node));
                return;
              }
              const error = new ConnectionTransientError({
                reason: "transport",
                detail: `${connection.label} disconnected.`,
              });
              Deferred.doneUnsafe(hello, Effect.fail(error));
              Deferred.doneUnsafe(closed, Effect.fail(error));
            },
          }),
      ),
      (socket) => Effect.sync(() => socket.close()),
    );
    yield* Deferred.await(hello).pipe(
      Effect.timeoutOrElse({
        duration: "15 seconds",
        orElse: () =>
          Effect.fail(
            new ConnectionTransientError({
              reason: "transport",
              detail: `${connection.label} did not answer.`,
            }),
          ),
      }),
    );
    const session = yield* makeV3Session({ socket, environmentId: connection.environmentId });
    return { ...session, closed: Deferred.await(closed) } satisfies RpcSession;
  });
