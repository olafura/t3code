import type {
  AgentOptions,
  InteractionUpdate,
  ModelSelection,
  SdkCredentialStore,
  SendOptions,
  ToolCall,
} from "@cursor/sdk";

/**
 * Cursor as an Agent Client Protocol agent, so a T3 node runs it like any other ACP
 * agent. Each ACP session is a local Cursor agent; a prompt is one Cursor run whose
 * deltas become `session/update` notifications. Signing in is Cursor's browser
 * login, whose URL goes to the client as a URL elicitation.
 *
 * The SDK is injected (`CursorSdk`) so the protocol can be tested without Cursor.
 */

export interface CursorSdk {
  readonly version: string;
  readonly store: SdkCredentialStore;
  /** `CURSOR_API_KEY`, which replaces the stored sign-in. */
  readonly envApiKey: string | undefined;
  readonly createAgent: (options: AgentOptions) => Promise<CursorAgent>;
  readonly resumeAgent: (agentId: string, options: AgentOptions) => Promise<CursorAgent>;
  readonly listModels: (
    apiKey: string,
  ) => Promise<ReadonlyArray<{ readonly id: string; readonly displayName: string }>>;
  readonly login: (options: {
    readonly store: SdkCredentialStore;
    readonly signal: AbortSignal;
    readonly onLoginUrl: (url: string) => void;
  }) => Promise<unknown>;
  /** Whether an SDK failure means the credentials were refused. */
  readonly isAuthError: (cause: unknown) => boolean;
}

export interface CursorAgent {
  readonly agentId: string;
  readonly send: (message: string, options: SendOptions) => Promise<CursorRun>;
  readonly close: () => void;
}

export interface CursorRun {
  readonly wait: () => Promise<{
    readonly status: string;
    readonly error?: { readonly message: string };
  }>;
  readonly cancel: () => Promise<void>;
}

/** The runtime mode the node started this process for (`--mode`). */
export type RuntimeMode = "full-access" | "approval-required" | "auto-accept-edits" | "auto";

type JsonRpcId = string | number;
type Message = {
  readonly id?: JsonRpcId;
  readonly method?: string;
  readonly params?: Record<string, unknown>;
  readonly result?: unknown;
  readonly error?: unknown;
};

class RpcError extends Error {
  readonly code: number;
  constructor(code: number, message: string) {
    super(message);
    this.code = code;
  }
}

// ACP's "authentication required".
const authRequired = () => new RpcError(-32000, "Sign in to Cursor to use this agent.");

interface Session {
  readonly agent: CursorAgent;
  model: ModelSelection;
  run: CursorRun | undefined;
}

export function makeCursorAcp(input: {
  readonly sdk: CursorSdk;
  readonly mode: RuntimeMode;
  readonly write: (message: object) => void;
}) {
  const { sdk, write } = input;
  const sessions = new Map<string, Session>();
  const pending = new Map<JsonRpcId, (result: unknown) => void>();
  let nextRequest = 0;

  const request = (method: string, params: object) =>
    new Promise<unknown>((resolve) => {
      const id = `cursor-${++nextRequest}`;
      pending.set(id, resolve);
      write({ jsonrpc: "2.0", id, method, params });
    });

  const apiKey = async () => sdk.envApiKey ?? (await sdk.store.load())?.apiKey;

  const requireKey = async () => {
    const key = await apiKey();
    if (key === undefined) throw authRequired();
    return key;
  };

  const agentOptions = (cwd: string, key: string, model: ModelSelection): AgentOptions => ({
    model,
    name: "T3 Code",
    mode: "agent",
    apiKey: key,
    local: {
      cwd,
      autoReview: input.mode === "approval-required",
      sandboxOptions: { enabled: input.mode !== "full-access" },
      enableAgentRetries: true,
    },
  });

  const modelOption = async (key: string, current: string) => {
    const models = await sdk.listModels(key).catch(() => []);
    return [
      {
        id: "model",
        name: "Model",
        type: "select",
        currentValue: current,
        options: [
          { value: "default", name: "Auto" },
          ...models.map((model) => ({ value: model.id, name: model.displayName })),
        ],
      },
    ];
  };

  const open = async (params: Record<string, unknown>, agentId?: string) => {
    const key = await requireKey();
    const cwd = String(params.cwd ?? process.cwd());
    const model: ModelSelection = { id: "default" };
    const agent = await guard(
      agentId === undefined
        ? sdk.createAgent(agentOptions(cwd, key, model))
        : sdk.resumeAgent(agentId, agentOptions(cwd, key, model)),
    );
    sessions.get(agent.agentId)?.agent.close();
    sessions.set(agent.agentId, { agent, model, run: undefined });
    return {
      ...(agentId === undefined ? { sessionId: agent.agentId } : {}),
      configOptions: await modelOption(key, model.id),
    };
  };

  // SDK failures from refused credentials become ACP's sign-in error.
  const guard = async <A>(promise: Promise<A>): Promise<A> => {
    try {
      return await promise;
    } catch (cause) {
      if (sdk.isAuthError(cause)) throw authRequired();
      throw cause;
    }
  };

  const session = (params: Record<string, unknown>) => {
    const found = sessions.get(String(params.sessionId));
    if (found === undefined)
      throw new RpcError(-32602, `Unknown session ${String(params.sessionId)}`);
    return found;
  };

  const prompt = async (params: Record<string, unknown>) => {
    const current = session(params);
    const sessionId = String(params.sessionId);
    const blocks = Array.isArray(params.prompt) ? params.prompt : [];
    const text = blocks
      .flatMap((block) =>
        typeof block === "object" &&
        block !== null &&
        "text" in block &&
        typeof block.text === "string"
          ? [block.text]
          : [],
      )
      .join("\n\n");
    const updates = makeUpdateTranslator((update) =>
      write({ jsonrpc: "2.0", method: "session/update", params: { sessionId, update } }),
    );
    const run = await guard(
      current.agent.send(text, {
        model: current.model,
        onDelta: ({ update }) => updates(update),
      }),
    );
    current.run = run;
    try {
      const result = await run.wait();
      if (result.status === "cancelled") return { stopReason: "cancelled" };
      if (result.status === "error")
        throw new RpcError(-32603, result.error?.message ?? "Cursor run failed");
      return { stopReason: "end_turn" };
    } finally {
      current.run = undefined;
    }
  };

  const handlers: Record<string, (params: Record<string, unknown>) => Promise<unknown>> = {
    initialize: async () => ({
      protocolVersion: 1,
      agentInfo: { name: "cursor", version: sdk.version },
      agentCapabilities: {
        loadSession: false,
        sessionCapabilities: { resume: {} },
        auth: { logout: {} },
      },
      authMethods:
        sdk.envApiKey === undefined
          ? [
              {
                id: "cursor-login",
                name: "Log in with Cursor",
                description: "Sign in on cursor.com in your browser.",
              },
            ]
          : [],
    }),
    authenticate: async () => {
      const aborted = new AbortController();
      await sdk.login({
        store: sdk.store,
        signal: aborted.signal,
        onLoginUrl: (url) => {
          void request("elicitation/create", {
            mode: "url",
            url,
            elicitationId: "cursor-login",
            message: "Sign in to Cursor",
          }).then((answer) => {
            const action = (answer as { readonly action?: unknown } | undefined)?.action;
            if (action !== "accept") aborted.abort();
          });
        },
      });
      return {};
    },
    logout: async () => {
      await sdk.store.clear();
      return {};
    },
    "session/new": (params) => open(params),
    "session/resume": (params) => open(params, String(params.sessionId)),
    "session/set_config_option": async (params) => {
      const current = session(params);
      if (params.configId === "model" && typeof params.value === "string") {
        current.model = { id: params.value };
      }
      return { configOptions: [] };
    },
    "session/prompt": prompt,
  };

  /** Handles one message from the client. */
  const receive = async (message: Message) => {
    if (message.method === undefined) {
      if (message.id !== undefined) pending.get(message.id)?.(message.result);
      if (message.id !== undefined) pending.delete(message.id);
      return;
    }
    if (message.method === "session/cancel") {
      await sessions.get(String(message.params?.sessionId))?.run?.cancel();
      return;
    }
    if (message.id === undefined) return;
    const handler = handlers[message.method];
    try {
      if (handler === undefined) throw new RpcError(-32601, message.method);
      const result = await handler(message.params ?? {});
      write({ jsonrpc: "2.0", id: message.id, result });
    } catch (cause) {
      const code = cause instanceof RpcError ? cause.code : -32603;
      const text = cause instanceof Error ? cause.message : String(cause);
      write({ jsonrpc: "2.0", id: message.id, error: { code, message: text } });
    }
  };

  return { receive };
}

/**
 * Turns one run's Cursor deltas into ACP updates. Text and thinking between tool
 * calls become separate messages, so each keeps its place in the transcript.
 */
export function makeUpdateTranslator(emit: (update: object) => void) {
  let segment = 0;
  let last: "text" | "thinking" | "tool" | undefined;
  const nextSegment = (kind: "text" | "thinking" | "tool") => {
    if (last !== kind) segment++;
    last = kind;
    return `segment-${segment}`;
  };

  return (update: InteractionUpdate) => {
    switch (update.type) {
      case "text-delta":
        emit({
          sessionUpdate: "agent_message_chunk",
          messageId: nextSegment("text"),
          content: { type: "text", text: update.text },
        });
        return;
      case "thinking-delta":
        emit({
          sessionUpdate: "agent_thought_chunk",
          messageId: nextSegment("thinking"),
          content: { type: "text", text: update.text },
        });
        return;
      case "tool-call-started":
        nextSegment("tool");
        emit({
          sessionUpdate: "tool_call",
          toolCallId: update.callId,
          status: "in_progress",
          ...toolFields(update.toolCall),
        });
        return;
      case "tool-call-completed": {
        nextSegment("tool");
        const output = toolOutput(update.toolCall);
        emit({
          sessionUpdate: "tool_call_update",
          toolCallId: update.callId,
          status: toolFailed(update.toolCall) ? "failed" : "completed",
          ...toolFields(update.toolCall),
          ...(output === ""
            ? {}
            : { content: [{ type: "content", content: { type: "text", text: output } }] }),
        });
        return;
      }
      default:
        return;
    }
  };
}

function toolFields(toolCall: ToolCall) {
  switch (toolCall.type) {
    case "shell":
      return {
        kind: "execute",
        title: toolCall.args.command,
        rawInput: { command: toolCall.args.command },
      };
    case "write":
    case "edit":
      return {
        kind: "edit",
        title: toolCall.args.path,
        locations: [{ path: toolCall.args.path }],
        rawInput: toolCall.args,
      };
    case "delete":
      return {
        kind: "delete",
        title: toolCall.args.path,
        locations: [{ path: toolCall.args.path }],
        rawInput: toolCall.args,
      };
    case "read":
      return {
        kind: "read",
        title: toolCall.args.path,
        locations: [{ path: toolCall.args.path }],
        rawInput: toolCall.args,
      };
    case "glob":
    case "grep":
    case "ls":
    case "semSearch":
    case "readLints":
      return { kind: "search", title: toolCall.type, rawInput: toolCall.args };
    case "mcp":
      return {
        kind: "other",
        title: `mcp__${toolCall.args.providerIdentifier ?? "mcp"}__${toolCall.args.toolName ?? "unknown"}`,
        rawInput: toolCall.args,
      };
    default:
      return { kind: "other", title: toolCall.type, rawInput: toolCall.args };
  }
}

function toolFailed(toolCall: ToolCall): boolean {
  if (toolCall.result?.status === "error") return true;
  return (
    toolCall.type === "mcp" &&
    toolCall.result?.status === "success" &&
    toolCall.result.value.isError === true
  );
}

/** A finished tool's output as text: a command's output, an edit's diff, or its result. */
function toolOutput(toolCall: ToolCall): string {
  const result = toolCall.result;
  if (result === undefined) return "";
  if (result.status !== "success")
    return typeof result.error === "string" ? result.error : JSON.stringify(result.error);
  if (toolCall.type === "shell" && toolCall.result?.status === "success") {
    const { stdout, stderr } = toolCall.result.value;
    return [stdout, stderr].filter((part) => part.length > 0).join("\n");
  }
  if (toolCall.type === "edit" && toolCall.result?.status === "success") {
    return toolCall.result.value.diffString ?? "";
  }
  const value = result.value;
  return typeof value === "string" ? value : JSON.stringify(value);
}
