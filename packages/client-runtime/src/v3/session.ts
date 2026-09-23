import {
  AcpRegistryOperationError,
  AssetAccessError,
  AssetWorkspaceResolutionError,
  AttachmentUploadSigningKeyError,
  PersistChatAttachmentsError,
  type AssetCreateUrlInput,
  AgentSessionImportProjectChangedError,
  AuthAccessStreamError,
  AuthAccessStreamEvent,
  AgentSessionImportProjectNotFoundError,
  AgentSessionScanError,
  ExternalLauncherError,
  ExternalLauncherUnknownEditorError,
  FilesystemBrowseError,
  GitCommandError,
  GitManagerError,
  GitManagerServiceError,
  KeybindingRule,
  KeybindingsConfigError,
  OrchestrationGetFullThreadDiffError,
  OrchestrationGetTurnDiffError,
  OrchestrationSearchThreadsError,
  ProjectListEntriesError,
  type ProjectListEntriesInput,
  ProjectMutationError,
  ProjectReadFileError,
  type ProjectReadFileInput,
  ProjectSearchContentsError,
  type ProjectSearchContentsInput,
  ProjectSearchEntriesError,
  type ProjectSearchEntriesInput,
  ProjectWriteFileError,
  type ProjectWriteFileInput,
  ProviderAuthState,
  ProviderSetupError,
  ReviewDiffPreviewError,
  VcsError,
  OrchestrationV2DispatchCommandError,
  OrchestrationV2GetShellSnapshotError,
  OrchestrationV2GetThreadProjectionError,
  OrchestrationV2ThreadLaunchError,
  ORCHESTRATION_V2_WS_METHODS,
  type ResolvedKeybindingsConfig,
  DiscoveredLocalServerList,
  PreviewError,
  ResourceTelemetrySnapshot,
  PreviewEvent,
  PreviewInvalidUrlError,
  PreviewSessionLookupError,
  ProjectCloneListEvent,
  ScheduledTaskError,
  SourceControlRepositoryError,
  ScheduledTaskListResult,
  ServerConfig,
  ServerProviderUpdateError,
  ServerProviders,
  ServerSettings,
  ServerSettingsError,
  type ProviderInstanceMutation,
  type ServerConfigStreamEvent,
  type ServerSettingsPatch,
  TerminalError,
  TerminalSessionLookupError,
  ThreadId,
  WS_METHODS,
  WorktreeSetupStreamEvent,
  WsRpcGroup,
} from "@t3tools/contracts";
import {
  compileResolvedKeybindingsConfig,
  mergeWithDefaultKeybindings,
} from "@t3tools/shared/keybindings";
import { isPreviewUrlNormalizationError, normalizePreviewUrl } from "@t3tools/shared/preview";
import { applyServerSettingsPatch } from "@t3tools/shared/serverSettings";
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

const decodeServerConfig = Schema.decodeUnknownSync(Schema.toCodecJson(ServerConfig));
const decodeKeybindingRule = Schema.decodeUnknownOption(KeybindingRule);
const decodeLauncherError = Schema.decodeUnknownOption(ExternalLauncherError);

/** A node's keybinding rules, merged with the defaults and compiled. */
function resolveKeybindings(rules: unknown): ResolvedKeybindingsConfig {
  const valid = Array.isArray(rules)
    ? rules.flatMap((rule) => Option.toArray(decodeKeybindingRule(rule)))
    : [];
  return mergeWithDefaultKeybindings(compileResolvedKeybindingsConfig(valid));
}

/** A node sends its raw keybinding rules; clients compile them. */
function decodeConfig(raw: unknown): ServerConfig {
  const config = decodeServerConfig(raw);
  const rules = (raw as { readonly keybindingRules?: unknown }).keybindingRules;
  return { ...config, keybindings: resolveKeybindings(rules) };
}
const decodeProviders = Schema.decodeUnknownSync(Schema.toCodecJson(ServerProviders));
const decodeAuthState = Schema.decodeUnknownSync(Schema.toCodecJson(ProviderAuthState));
const decodeWorktreeSetup = Schema.decodeUnknownSync(Schema.toCodecJson(WorktreeSetupStreamEvent));
const decodeScheduledTasks = Schema.decodeUnknownSync(Schema.toCodecJson(ScheduledTaskListResult));
const decodeScheduledTaskError = Schema.decodeUnknownOption(ScheduledTaskError);
const decodeProjectClones = Schema.decodeUnknownSync(Schema.toCodecJson(ProjectCloneListEvent));
const decodeRepositoryError = Schema.decodeUnknownOption(SourceControlRepositoryError);
const decodeProviderUpdateError = Schema.decodeUnknownOption(ServerProviderUpdateError);
const decodePreviewError = Schema.decodeUnknownOption(PreviewError);
const decodePreviewEvent = Schema.decodeUnknownSync(Schema.toCodecJson(PreviewEvent));
const decodeLocalServers = Schema.decodeUnknownSync(Schema.toCodecJson(DiscoveredLocalServerList));
const decodeTelemetry = Schema.decodeUnknownSync(Schema.toCodecJson(ResourceTelemetrySnapshot));
const decodeAuthAccess = Schema.decodeUnknownSync(Schema.toCodecJson(AuthAccessStreamEvent));
const decodeSetupError = Schema.decodeUnknownOption(ProviderSetupError);
const decodeTerminalError = Schema.decodeUnknownOption(TerminalError);
const settingsCodec = Schema.toCodecJson(ServerSettings);
const isServerSettingsError = Schema.is(ServerSettingsError);
const decodeSettings = Schema.decodeUnknownEffect(settingsCodec);
const decodeSettingsSync = Schema.decodeUnknownSync(settingsCodec);
const encodeSettings = Schema.encodeEffect(settingsCodec);

function settingsError(operation: "read-file" | "write-file", cause: unknown) {
  return new ServerSettingsError({ settingsPath: "settings.json", operation, cause });
}

function isStaleSettings(cause: unknown): boolean {
  return (
    cause instanceof ClusterRpcError &&
    (cause.detail as { readonly _tag?: string } | undefined)?._tag === "StaleSettings"
  );
}

function withProviderInstance(
  settings: ServerSettings,
  mutation: ProviderInstanceMutation,
): ServerSettings {
  const providerInstances = { ...settings.providerInstances };
  if (mutation.operation === "remove") delete providerInstances[mutation.instanceId];
  else providerInstances[mutation.instanceId] = mutation.instance;
  return { ...settings, providerInstances };
}

// A node's launch result leaves out the thread projection: nothing reads it, and the
// thread's stream shape already carries that state.
const UNDECODED_RESULTS: ReadonlySet<string> = new Set([ORCHESTRATION_V2_WS_METHODS.launchThread]);
const decodeReviewError = Schema.decodeUnknownOption(ReviewDiffPreviewError);
const decodeVcsError = Schema.decodeUnknownOption(Schema.Union([GitManagerServiceError, VcsError]));

/** A node's git error, or a command error carrying its message. */
function vcsError(operation: string, cwd: string, detail: unknown, message: string) {
  return decodeVcsError(detail).pipe(
    Option.getOrElse(
      () => new GitCommandError({ operation, command: "git", cwd, detail: message }),
    ),
  );
}
const decodeAcpRegistryError = Schema.decodeUnknownOption(AcpRegistryOperationError);
const decodeAgentSessionError = Schema.decodeUnknownOption(
  Schema.Union([
    AgentSessionImportProjectChangedError,
    AgentSessionImportProjectNotFoundError,
    AgentSessionScanError,
  ]),
);

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

    // The node's config, then its settings and providers whenever they change.
    const serverConfig = () =>
      shapeStream(
        socket,
        { type: "config", node },
        (frame): ReadonlyArray<ServerConfigStreamEvent> => {
          if (frame.t === "config")
            return [
              {
                version: 1 as const,
                type: "snapshot" as const,
                config: decodeConfig(frame.config),
              },
            ];
          if (frame.t === "config.settings")
            return [
              {
                version: 1 as const,
                type: "settingsUpdated" as const,
                payload: { settings: decodeSettingsSync(frame.settings) },
              },
            ];
          if (frame.t === "config.keybindings")
            return [
              {
                version: 1 as const,
                type: "keybindingsUpdated" as const,
                payload: { keybindings: resolveKeybindings(frame.rules), issues: [] },
              },
            ];
          if (frame.t === "config.providers")
            return [
              {
                version: 1 as const,
                type: "providerStatuses" as const,
                payload: { providers: decodeProviders(frame.providers) },
              },
            ];
          return [];
        },
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

    const searchThreads = forward(
      ORCHESTRATION_V2_WS_METHODS.searchThreads,
      (_request: object, message) => new OrchestrationSearchThreadsError({ message }),
    );

    const archivedShell = forward(
      ORCHESTRATION_V2_WS_METHODS.getArchivedShellSnapshot,
      (_request: object, message) => new OrchestrationV2GetShellSnapshotError({ message }),
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

    // Attachments upload to, and files are served from, the thread's node.
    const decodeAssetError = Schema.decodeUnknownOption(AssetAccessError);
    const createAssetUrl = forward(
      WS_METHODS.assetsCreateUrl,
      (request: AssetCreateUrlInput, message, cause) =>
        decodeAssetError(cause instanceof ClusterRpcError ? cause.detail : undefined).pipe(
          Option.getOrElse(
            () => new AssetWorkspaceResolutionError({ resource: request.resource, cause: message }),
          ),
        ),
    );
    const createUploadUrl = forward(
      WS_METHODS.attachmentsCreateUploadUrl,
      (_request: object, message) => new AttachmentUploadSigningKeyError({ cause: message }),
    );
    const persistAttachments = forward(
      WS_METHODS.assetsPersistChatAttachments,
      (_request: object, message, cause) =>
        Schema.decodeUnknownOption(PersistChatAttachmentsError)(
          cause instanceof ClusterRpcError ? cause.detail : undefined,
        ).pipe(Option.getOrElse(() => new PersistChatAttachmentsError({ message }))),
    );
    const deleteAttachment = forward(
      WS_METHODS.attachmentsDelete,
      (_request: object, _message, cause) => cause,
    );

    // A project's files are read and searched on its node.
    const projectFiles = <R extends { readonly cwd: string }, E>(
      tag: string,
      decodeError: (detail: unknown) => Option.Option<E>,
      fallback: (request: R, message: string) => E,
    ) =>
      forward(tag, (request: R, message, cause) =>
        decodeError(cause instanceof ClusterRpcError ? cause.detail : undefined).pipe(
          Option.getOrElse(() => fallback(request, message)),
        ),
      );

    // Keybinding rules are stored on the node and compiled here.
    const keybindingCommand = (method: string) => (request: object) =>
      nodeCall(method, request).pipe(
        Effect.map((result) => ({
          keybindings: resolveKeybindings((result as { readonly rules?: unknown }).rules),
          issues: [],
        })),
        Effect.mapError(
          (cause) =>
            new KeybindingsConfigError({
              configPath: "keybindings.json",
              detail: cause.message,
              cause,
            }),
        ),
      );

    const openInEditor = forward(
      WS_METHODS.shellOpenInEditor,
      (request: { readonly editor: string }, _message, cause) =>
        decodeLauncherError(cause instanceof ClusterRpcError ? cause.detail : undefined).pipe(
          Option.getOrElse(
            () => new ExternalLauncherUnknownEditorError({ editor: request.editor }),
          ),
        ),
    );

    // Scheduled tasks run on their node; the list streams whole on every change.
    const scheduledTasks = () =>
      shapeStream(socket, { type: "scheduledTasks", node }, (frame) =>
        frame.t === "scheduledTasks" ? [decodeScheduledTasks({ tasks: frame.tasks })] : [],
      );
    const scheduledTaskCommand = (tag: string) =>
      forward(tag, (_request: object, message, cause) =>
        decodeScheduledTaskError(cause instanceof ClusterRpcError ? cause.detail : undefined).pipe(
          Option.getOrElse(() => new ScheduledTaskError({ message })),
        ),
      );

    // Repositories are looked up, cloned, and published by the node's host CLIs.
    const repositoryCommand = (tag: string, operation: string) =>
      forward(tag, (request: { readonly provider?: string }, message, cause) =>
        decodeRepositoryError(cause instanceof ClusterRpcError ? cause.detail : undefined).pipe(
          Option.getOrElse(
            () =>
              new SourceControlRepositoryError({
                provider: (request.provider ??
                  "unknown") as SourceControlRepositoryError["provider"],
                operation,
                detail: message,
              }),
          ),
        ),
      );
    const projectClones = () =>
      shapeStream(socket, { type: "projectClones", node }, (frame) =>
        frame.t === "projectClones" ? [decodeProjectClones(frame.clones)] : [],
      );

    // Preview tabs are tracked on the node; URLs are normalized here, as Node does.
    type PreviewRequest = {
      readonly threadId: string;
      readonly tabId?: string;
      readonly url?: string;
    };
    const previewCommand = (tag: string) =>
      forward(tag, (request: PreviewRequest, _message, cause) =>
        decodePreviewError(cause instanceof ClusterRpcError ? cause.detail : undefined).pipe(
          Option.getOrElse(
            () =>
              new PreviewSessionLookupError({
                threadId: request.threadId,
                tabId: request.tabId ?? "",
              }),
          ),
        ),
      );
    const withPreviewUrl =
      (tag: string) =>
      (request: PreviewRequest): Effect.Effect<unknown, unknown> => {
        if (request.url === undefined) return previewCommand(tag)(request);
        const rawUrl = request.url;
        return Effect.try({
          try: () => normalizePreviewUrl(rawUrl),
          catch: (cause) =>
            new PreviewInvalidUrlError({
              inputLength: rawUrl.length,
              reason: isPreviewUrlNormalizationError(cause) ? cause.reason : "unexpected",
              ...(isPreviewUrlNormalizationError(cause) && cause.protocol !== undefined
                ? { protocol: cause.protocol }
                : {}),
              cause,
            }),
        }).pipe(Effect.flatMap((url) => previewCommand(tag)({ ...request, url })));
      };
    const previewEvents = () =>
      shapeStream(socket, { type: "preview", node }, (frame) =>
        frame.t === "preview" ? [decodePreviewEvent(frame.event)] : [],
      );
    const localServers = () =>
      shapeStream(socket, { type: "localServers", node }, (frame) =>
        frame.t === "localServers" ? [decodeLocalServers(frame.list)] : [],
      );

    // A client manages the connections of the node it is paired with; other
    // nodes are reached through it without a session of their own.
    const authAccess = () =>
      socket.connectedNode() === node
        ? shapeStream(
            socket,
            { type: "authAccess" },
            (frame) => (frame.t === "authAccess" ? [decodeAuthAccess(frame.event)] : []),
            (frame) => new AuthAccessStreamError({ message: String(frame.reason) }),
          )
        : Stream.fail(
            new AuthAccessStreamError({
              message: "Manage this node's connections from a client paired with it directly.",
            }),
          );

    // The node samples its processes faster while this is subscribed.
    const resourceTelemetry = () =>
      shapeStream(socket, { type: "resourceTelemetry", node }, (frame) =>
        frame.t === "resourceTelemetry" ? [decodeTelemetry(frame.snapshot)] : [],
      );
    const backgroundPolicy = forward(
      WS_METHODS.serverGetBackgroundPolicy,
      (_request: object, message) => new ClusterRpcError(message, undefined),
    );

    // A new thread's worktree is prepared on its node.
    const worktreeSetup = (request: { readonly threadId: string }) =>
      shapeStream(socket, { type: "worktreeSetup", node, threadId: request.threadId }, (frame) =>
        frame.t === "worktreeSetup" ? [decodeWorktreeSetup(frame.event)] : [],
      );
    const cancelWorktreeSetup = forward(
      WS_METHODS.worktreeSetupCancel,
      (_request: object, _message, cause) => cause,
    );

    // Signing a provider in happens on the node that runs it.
    const setupError = (instanceId: string, operation: string, message: string, detail: unknown) =>
      decodeSetupError(detail).pipe(
        Option.getOrElse(
          () =>
            new ProviderSetupError({
              instanceId: instanceId as ProviderSetupError["instanceId"],
              operation,
              detail: message,
            }),
        ),
      );

    const refreshProviders = forward(
      WS_METHODS.serverRefreshProviders,
      (request: { readonly instanceId?: string }, message, cause) =>
        setupError(
          request.instanceId ?? "codex",
          "refresh",
          message,
          cause instanceof ClusterRpcError ? cause.detail : undefined,
        ),
    );

    const providerAuthCommand = (tag: string, operation: string) =>
      forward(tag, (request: { readonly instanceId: string }, message, cause) =>
        setupError(
          request.instanceId,
          operation,
          message,
          cause instanceof ClusterRpcError ? cause.detail : undefined,
        ),
      );

    const providerAuthSubscribe = (request: { readonly instanceId: string }) =>
      shapeStream(
        socket,
        { type: "providerAuth", node, instanceId: request.instanceId },
        (frame) => (frame.t === "providerAuth" ? [decodeAuthState(frame.state)] : []),
        (frame) => setupError(request.instanceId, "subscribe", String(frame.reason), frame.detail),
      );

    // ACP Registry search and installs run on the node that will run the agent.
    const acpRegistryCommand = (tag: string) =>
      forward(tag, (_request: object, message, cause) =>
        decodeAcpRegistryError(cause instanceof ClusterRpcError ? cause.detail : undefined).pipe(
          Option.getOrElse(
            () => new AcpRegistryOperationError({ reason: "registry_unavailable", message }),
          ),
        ),
      );

    const agentSessionCommand = (tag: string) =>
      forward(tag, (_request: object, message, cause) =>
        decodeAgentSessionError(cause instanceof ClusterRpcError ? cause.detail : undefined).pipe(
          Option.getOrElse(
            () => new AgentSessionScanError({ operation: "read-projects", cause: message }),
          ),
        ),
      );

    // A checkout's git status streams from its node; git actions are forwarded.
    const vcsStatus = (request: { readonly cwd: string }) =>
      shapeStream(
        socket,
        { type: "vcs", node, cwd: request.cwd },
        (frame) => (frame.t === "vcs" ? [frame.event] : []),
        (frame) =>
          vcsError(WS_METHODS.subscribeVcsStatus, request.cwd, frame.detail, String(frame.reason)),
      );

    // Runs once on the checkout's node. The stream ends with the action, failing
    // after action_failed as the Node server's does.
    const runStackedAction = (request: { readonly cwd: string; readonly actionId: string }) =>
      Stream.callback<unknown, unknown>((queue) =>
        Effect.acquireRelease(
          Effect.sync(() =>
            socket.subscribe({ type: "gitAction", node, input: request }, (frame) => {
              if (frame.t === "error") {
                Queue.failCauseUnsafe(
                  queue,
                  Cause.fail(
                    vcsError(
                      WS_METHODS.gitRunStackedAction,
                      request.cwd,
                      frame.detail,
                      String(frame.reason),
                    ),
                  ),
                );
                return;
              }
              if (frame.t !== "gitAction") return;
              const event = frame.event as { readonly kind: string; readonly message?: string };
              Queue.offerAllUnsafe(queue, [event]);
              if (event.kind === "action_finished") Queue.endUnsafe(queue);
              if (event.kind === "action_failed") {
                Queue.failCauseUnsafe(
                  queue,
                  Cause.fail(
                    new GitManagerError({
                      operation: WS_METHODS.gitRunStackedAction,
                      cwd: request.cwd,
                      detail: event.message ?? "The git action failed.",
                    }),
                  ),
                );
              }
            }),
          ),
          (unsubscribe) => Effect.sync(unsubscribe),
        ),
      );

    const vcsCommand = (tag: string) =>
      forward(tag, (request: { readonly cwd: string }, message, cause) =>
        vcsError(
          tag,
          request.cwd,
          cause instanceof ClusterRpcError ? cause.detail : undefined,
          message,
        ),
      );

    const getFullThreadDiff = forward(
      ORCHESTRATION_V2_WS_METHODS.getFullThreadDiff,
      (_request: object, message) => new OrchestrationGetFullThreadDiffError({ message }),
    );

    // A node stores settings; the patch is applied here with the shared rules, to
    // the version the node has. A concurrent write sends it round again.
    const nodeCall = (method: string, payload: unknown) =>
      Effect.tryPromise({
        try: () => socket.call(input.environmentId, method, payload),
        catch: (cause) =>
          cause instanceof ClusterRpcError ? cause : new ClusterRpcError(String(cause), undefined),
      });

    const getSettings = forward(WS_METHODS.serverGetSettings, (_request: object, _message, cause) =>
      settingsError("read-file", cause),
    );

    const updateSettings = (request: {
      readonly patch: ServerSettingsPatch;
      readonly providerInstanceMutation?: ProviderInstanceMutation;
    }) =>
      Effect.gen(function* () {
        const current = (yield* nodeCall("t3.readSettings", {})) as {
          readonly settings: unknown;
          readonly version: number;
        };
        const settings = yield* decodeSettings(current.settings);
        const mutation = request.providerInstanceMutation;
        if (
          mutation?.operation === "create" &&
          settings.providerInstances[mutation.instanceId] !== undefined
        ) {
          return yield* new ServerSettingsError({
            settingsPath: "settings.json",
            operation: "create-provider-instance",
            providerInstanceId: mutation.instanceId,
          });
        }
        const patched = applyServerSettingsPatch(settings, request.patch);
        const next = mutation === undefined ? patched : withProviderInstance(patched, mutation);
        yield* nodeCall("t3.writeSettings", {
          settings: yield* encodeSettings(next),
          version: current.version,
        });
        return next;
      }).pipe(
        Effect.retry({ times: 3, while: isStaleSettings }),
        Effect.mapError((cause) =>
          isServerSettingsError(cause) ? cause : settingsError("write-file", cause),
        ),
      );

    // A thread's projection, from its entities fetched at once: a socket holds one
    // subscription per stream, and the open thread view usually has it.
    const threadProjection = (request: { readonly threadId: ThreadId }) => {
      const failure = (message: string, cause?: unknown) =>
        new OrchestrationV2GetThreadProjectionError({ threadId: request.threadId, message, cause });
      return nodeCall("t3.threadRows", { threadId: request.threadId }).pipe(
        Effect.mapError((cause) => failure(cause.message, cause)),
        Effect.flatMap((result) => {
          const { rows, offset, at } = result as {
            readonly rows: ReadonlyArray<ShapeRow>;
            readonly offset: number;
            readonly at: number | null;
          };
          const [item] = new ThreadShapeFold(request.threadId).snapshot({
            rows,
            part: 0,
            done: true,
            offset,
            at,
          });
          return item?.kind === "snapshot"
            ? Effect.succeed(item.projection)
            : Effect.fail(failure(`Thread ${request.threadId} was not found.`));
        }),
      );
    };

    const served: Record<string, (request: never) => unknown> = {
      [WS_METHODS.projectsMutate]: mutateProject,
      [WS_METHODS.filesystemBrowse]: browse,
      [ORCHESTRATION_V2_WS_METHODS.dispatchCommand]: dispatchCommand,
      [ORCHESTRATION_V2_WS_METHODS.launchThread]: launchThread,
      [ORCHESTRATION_V2_WS_METHODS.getTurnDiff]: getTurnDiff,
      [ORCHESTRATION_V2_WS_METHODS.getFullThreadDiff]: getFullThreadDiff,
      [ORCHESTRATION_V2_WS_METHODS.subscribeShell]: shell,
      [ORCHESTRATION_V2_WS_METHODS.subscribeThread]: thread,
      [ORCHESTRATION_V2_WS_METHODS.getThreadProjection]: threadProjection,
      [ORCHESTRATION_V2_WS_METHODS.searchThreads]: searchThreads,
      [WS_METHODS.serverUpsertKeybinding]: keybindingCommand("t3.upsertKeybinding"),
      [WS_METHODS.serverRemoveKeybinding]: keybindingCommand("t3.removeKeybinding"),
      [WS_METHODS.shellOpenInEditor]: openInEditor,
      [WS_METHODS.scheduledTasksSubscribe]: scheduledTasks,
      [WS_METHODS.serverDiscoverSourceControl]: forward(
        WS_METHODS.serverDiscoverSourceControl,
        (_request: object, _message, cause) => cause,
      ),
      [WS_METHODS.sourceControlLookupRepository]: repositoryCommand(
        WS_METHODS.sourceControlLookupRepository,
        "lookupRepository",
      ),
      [WS_METHODS.sourceControlCloneRepository]: repositoryCommand(
        WS_METHODS.sourceControlCloneRepository,
        "cloneRepository",
      ),
      [WS_METHODS.sourceControlPublishRepository]: repositoryCommand(
        WS_METHODS.sourceControlPublishRepository,
        "publishRepository",
      ),
      [WS_METHODS.projectCloneStart]: repositoryCommand(
        WS_METHODS.projectCloneStart,
        "cloneRepository",
      ),
      [WS_METHODS.projectCloneRetry]: repositoryCommand(
        WS_METHODS.projectCloneRetry,
        "cloneRepository",
      ),
      [WS_METHODS.projectCloneCancel]: forward(
        WS_METHODS.projectCloneCancel,
        (_request: object, _message, cause) => cause,
      ),
      [WS_METHODS.subscribeProjectClones]: projectClones,
      ...Object.fromEntries(
        [
          WS_METHODS.serverGetProcessDiagnostics,
          WS_METHODS.serverSignalProcess,
          WS_METHODS.serverGetTraceDiagnostics,
          WS_METHODS.serverGetHostResources,
          WS_METHODS.serverGetProcessResourceHistory,
          WS_METHODS.serverGetResourceTelemetryHistory,
          WS_METHODS.serverRetryResourceTelemetry,
        ].map((tag) => [tag, forward(tag, (_request: object, _message, cause) => cause)]),
      ),
      [WS_METHODS.subscribeResourceTelemetry]: resourceTelemetry,
      [WS_METHODS.subscribeAuthAccess]: authAccess,
      [WS_METHODS.serverGetBackgroundPolicy]: backgroundPolicy,
      // Nodes have no client-driven policy, so it never changes after the first read.
      [WS_METHODS.subscribeBackgroundPolicy]: (request: object) =>
        Stream.concat(Stream.fromEffect(backgroundPolicy(request)), Stream.never),
      [WS_METHODS.previewOpen]: withPreviewUrl(WS_METHODS.previewOpen),
      [WS_METHODS.previewNavigate]: withPreviewUrl(WS_METHODS.previewNavigate),
      [WS_METHODS.previewReportStatus]: previewCommand(WS_METHODS.previewReportStatus),
      [WS_METHODS.previewResize]: previewCommand(WS_METHODS.previewResize),
      [WS_METHODS.previewRefresh]: previewCommand(WS_METHODS.previewRefresh),
      [WS_METHODS.previewClose]: previewCommand(WS_METHODS.previewClose),
      [WS_METHODS.previewList]: previewCommand(WS_METHODS.previewList),
      [WS_METHODS.subscribePreviewEvents]: previewEvents,
      [WS_METHODS.subscribeDiscoveredLocalServers]: localServers,
      [WS_METHODS.scheduledTasksList]: scheduledTaskCommand(WS_METHODS.scheduledTasksList),
      [WS_METHODS.scheduledTasksUpsert]: scheduledTaskCommand(WS_METHODS.scheduledTasksUpsert),
      [WS_METHODS.scheduledTasksDelete]: scheduledTaskCommand(WS_METHODS.scheduledTasksDelete),
      [WS_METHODS.scheduledTasksSetEnabled]: scheduledTaskCommand(
        WS_METHODS.scheduledTasksSetEnabled,
      ),
      [WS_METHODS.scheduledTasksRunNow]: scheduledTaskCommand(WS_METHODS.scheduledTasksRunNow),
      [WS_METHODS.serverRefreshProviders]: refreshProviders,
      [WS_METHODS.serverUpdateProvider]: forward(
        WS_METHODS.serverUpdateProvider,
        (request: { readonly provider: string }, message, cause) =>
          decodeProviderUpdateError(
            cause instanceof ClusterRpcError ? cause.detail : undefined,
          ).pipe(
            Option.getOrElse(
              () =>
                new ServerProviderUpdateError({
                  provider: request.provider as ServerProviderUpdateError["provider"],
                  reason: message,
                }),
            ),
          ),
      ),
      // Nodes have no background policy that client activity would steer.
      [WS_METHODS.serverReportClientActivity]: () => Effect.void,
      [ORCHESTRATION_V2_WS_METHODS.getArchivedShellSnapshot]: archivedShell,
      [WS_METHODS.serverSearchAcpRegistry]: acpRegistryCommand(WS_METHODS.serverSearchAcpRegistry),
      [WS_METHODS.serverPrepareAcpRegistryAgent]: acpRegistryCommand(
        WS_METHODS.serverPrepareAcpRegistryAgent,
      ),
      [WS_METHODS.serverUninstallAcpRegistryManagedBinary]: acpRegistryCommand(
        WS_METHODS.serverUninstallAcpRegistryManagedBinary,
      ),
      [WS_METHODS.serverListAcpRegistrySessions]: acpRegistryCommand(
        WS_METHODS.serverListAcpRegistrySessions,
      ),
      [WS_METHODS.serverImportAcpRegistrySession]: acpRegistryCommand(
        WS_METHODS.serverImportAcpRegistrySession,
      ),
      [WS_METHODS.serverDeleteAcpRegistrySession]: acpRegistryCommand(
        WS_METHODS.serverDeleteAcpRegistrySession,
      ),
      [WS_METHODS.serverListAcpRegistryProviders]: acpRegistryCommand(
        WS_METHODS.serverListAcpRegistryProviders,
      ),
      [WS_METHODS.serverSetAcpRegistryProvider]: acpRegistryCommand(
        WS_METHODS.serverSetAcpRegistryProvider,
      ),
      [WS_METHODS.serverDisableAcpRegistryProvider]: acpRegistryCommand(
        WS_METHODS.serverDisableAcpRegistryProvider,
      ),
      [WS_METHODS.serverLogoutAcpRegistry]: acpRegistryCommand(WS_METHODS.serverLogoutAcpRegistry),
      [WS_METHODS.assetsCreateUrl]: createAssetUrl,
      [WS_METHODS.attachmentsCreateUploadUrl]: createUploadUrl,
      [WS_METHODS.attachmentsDelete]: deleteAttachment,
      [WS_METHODS.assetsPersistChatAttachments]: persistAttachments,
      [WS_METHODS.projectsSearchEntries]: projectFiles(
        WS_METHODS.projectsSearchEntries,
        Schema.decodeUnknownOption(ProjectSearchEntriesError),
        (request: ProjectSearchEntriesInput, detail) =>
          new ProjectSearchEntriesError({
            cwd: request.cwd,
            queryLength: request.query.length,
            limit: request.limit,
            failure: "search_index_search_failed",
            detail,
          }),
      ),
      [WS_METHODS.projectsListEntries]: projectFiles(
        WS_METHODS.projectsListEntries,
        Schema.decodeUnknownOption(ProjectListEntriesError),
        (request: ProjectListEntriesInput, detail) =>
          new ProjectListEntriesError({
            cwd: request.cwd,
            failure: "directory_list_failed",
            detail,
          }),
      ),
      [WS_METHODS.projectsSearchContents]: projectFiles(
        WS_METHODS.projectsSearchContents,
        Schema.decodeUnknownOption(ProjectSearchContentsError),
        (request: ProjectSearchContentsInput, detail) =>
          new ProjectSearchContentsError({
            cwd: request.cwd,
            queryLength: request.query.length,
            limit: request.limit,
            failure: "search_index_search_failed",
            detail,
          }),
      ),
      [WS_METHODS.projectsReadFile]: projectFiles(
        WS_METHODS.projectsReadFile,
        Schema.decodeUnknownOption(ProjectReadFileError),
        (request: ProjectReadFileInput) =>
          new ProjectReadFileError({ ...request, failure: "operation_failed" }),
      ),
      [WS_METHODS.projectsWriteFile]: projectFiles(
        WS_METHODS.projectsWriteFile,
        Schema.decodeUnknownOption(ProjectWriteFileError),
        (request: ProjectWriteFileInput) =>
          new ProjectWriteFileError({
            cwd: request.cwd,
            relativePath: request.relativePath,
            failure: "operation_failed",
          }),
      ),
      [WS_METHODS.subscribeWorktreeSetup]: worktreeSetup,
      [WS_METHODS.worktreeSetupCancel]: cancelWorktreeSetup,
      [WS_METHODS.providerAuthSubscribe]: providerAuthSubscribe,
      [WS_METHODS.providerAuthStart]: providerAuthCommand(WS_METHODS.providerAuthStart, "start"),
      [WS_METHODS.providerAuthRespond]: providerAuthCommand(
        WS_METHODS.providerAuthRespond,
        "respond",
      ),
      [WS_METHODS.providerAuthCancel]: providerAuthCommand(WS_METHODS.providerAuthCancel, "cancel"),
      [WS_METHODS.providerAuthLogout]: providerAuthCommand(WS_METHODS.providerAuthLogout, "logout"),
      [WS_METHODS.providerAuthComplete]: providerAuthCommand(
        WS_METHODS.providerAuthComplete,
        "complete",
      ),
      [WS_METHODS.agentSessionsScan]: agentSessionCommand(WS_METHODS.agentSessionsScan),
      [WS_METHODS.agentSessionsImport]: agentSessionCommand(WS_METHODS.agentSessionsImport),
      [WS_METHODS.subscribeVcsStatus]: vcsStatus,
      [WS_METHODS.gitRunStackedAction]: runStackedAction,
      [WS_METHODS.vcsRefreshStatus]: vcsCommand(WS_METHODS.vcsRefreshStatus),
      [WS_METHODS.vcsListRefs]: vcsCommand(WS_METHODS.vcsListRefs),
      [WS_METHODS.vcsSwitchRef]: vcsCommand(WS_METHODS.vcsSwitchRef),
      [WS_METHODS.vcsCreateRef]: vcsCommand(WS_METHODS.vcsCreateRef),
      [WS_METHODS.vcsInit]: vcsCommand(WS_METHODS.vcsInit),
      [WS_METHODS.vcsPull]: vcsCommand(WS_METHODS.vcsPull),
      [WS_METHODS.vcsCreateWorktree]: vcsCommand(WS_METHODS.vcsCreateWorktree),
      [WS_METHODS.vcsRemoveWorktree]: vcsCommand(WS_METHODS.vcsRemoveWorktree),
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
      [WS_METHODS.serverGetSettings]: getSettings,
      [WS_METHODS.serverUpdateSettings]: updateSettings,
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
