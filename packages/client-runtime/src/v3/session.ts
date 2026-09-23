import {
  OrchestrationV2DispatchCommandError,
  OrchestrationV2ThreadLaunchError,
  ORCHESTRATION_V2_WS_METHODS,
  ServerConfig,
  ThreadId,
  WS_METHODS,
  WsRpcGroup,
} from "@t3tools/contracts";
import * as Deferred from "effect/Deferred";
import * as Effect from "effect/Effect";
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
import { ClusterSocket, type Shape, type ShapeFrame } from "./clusterSocket.ts";
import { ShellShapeFold, type ShellRow } from "./shellShape.ts";
import { ThreadShapeFold, type ShapeEvent, type ShapeRow } from "./threadShape.ts";

const decodeConfig = Schema.decodeUnknownSync(Schema.toCodecJson(ServerConfig));

/** Streams one shape's frames, folded into items, for as long as it is consumed. */
function shapeStream<A>(
  socket: ClusterSocket,
  shape: Shape,
  fold: (frame: ShapeFrame) => ReadonlyArray<A>,
): Stream.Stream<A> {
  return Stream.callback<A>((queue) =>
    Effect.acquireRelease(
      Effect.sync(() =>
        socket.subscribe(shape, (frame) => {
          Queue.offerAllUnsafe(queue, fold(frame));
        }),
      ),
      (unsubscribe) => Effect.sync(unsubscribe),
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

    // Commands run on the environment's node; failures surface as the contract errors.
    const dispatchCommand = (command: { readonly commandId: string; readonly type: string }) =>
      Effect.tryPromise({
        try: () =>
          socket.call(input.environmentId, ORCHESTRATION_V2_WS_METHODS.dispatchCommand, command),
        catch: (cause) =>
          new OrchestrationV2DispatchCommandError({
            commandId: command.commandId as never,
            commandType: command.type as never,
            message: cause instanceof Error ? cause.message : String(cause),
          }),
      });

    const launchThread = (request: { readonly commandId: string; readonly projectId: string }) =>
      Effect.tryPromise({
        try: () =>
          socket.call(input.environmentId, ORCHESTRATION_V2_WS_METHODS.launchThread, request),
        catch: (cause) =>
          new OrchestrationV2ThreadLaunchError({
            commandId: request.commandId as never,
            projectId: request.projectId as never,
            message: cause instanceof Error ? cause.message : String(cause),
          }),
      });

    const served: Record<string, (request: never) => unknown> = {
      [ORCHESTRATION_V2_WS_METHODS.dispatchCommand]: dispatchCommand,
      [ORCHESTRATION_V2_WS_METHODS.launchThread]: launchThread,
      [ORCHESTRATION_V2_WS_METHODS.subscribeShell]: shell,
      [ORCHESTRATION_V2_WS_METHODS.subscribeThread]: thread,
      [WS_METHODS.serverGetConfig]: () => initialConfig,
      [WS_METHODS.serverProbe]: () => Effect.void,
      [WS_METHODS.subscribeServerConfig]: serverConfig,
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
