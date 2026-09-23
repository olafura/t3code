import type { InteractionUpdate, SendOptions, StoredSdkCredentials } from "@cursor/sdk";
import { describe, expect, it } from "vite-plus/test";

import { makeCursorAcp, type CursorSdk } from "./agent.ts";

const credentials: StoredSdkCredentials = {
  version: 1,
  backendUrl: "https://api.cursor.test",
  apiKey: "key-1",
  createdAtMs: 0,
};

/** A Cursor SDK whose runs replay `updates` and finish (or wait for cancel). */
function fakeSdk(updates: ReadonlyArray<InteractionUpdate>) {
  let stored: StoredSdkCredentials | undefined;
  const sent: Array<{ message: string; options: SendOptions }> = [];
  let finishLogin = () => {};
  const sdk: CursorSdk = {
    version: "test",
    envApiKey: undefined,
    store: {
      load: async () => stored,
      save: async (next) => {
        stored = next;
      },
      clear: async () => {
        stored = undefined;
      },
    },
    listModels: async () => [{ id: "gpt-9", displayName: "GPT 9" }],
    login: ({ store, signal, onLoginUrl }) =>
      new Promise((resolve, reject) => {
        signal.addEventListener("abort", () => reject(new Error("login declined")));
        onLoginUrl("https://cursor.test/login");
        finishLogin = () => void store.save(credentials).then(resolve);
      }),
    createAgent: async () => agent,
    resumeAgent: async () => agent,
    isAuthError: () => false,
  };
  let cancelled: (() => void) | undefined;
  const agent = {
    agentId: "agent-1",
    close: () => {},
    send: async (message: string, options: SendOptions) => {
      sent.push({ message, options });
      for (const update of updates) await options.onDelta?.({ update });
      return {
        wait: () =>
          message.includes("wait")
            ? new Promise<{ status: string }>((resolve) => {
                cancelled = () => resolve({ status: "cancelled" });
              })
            : Promise.resolve({ status: "finished" }),
        cancel: async () => cancelled?.(),
      };
    },
  };
  // The user finishing the sign-in page.
  return { sdk, sent, finishLogin: () => finishLogin() };
}

/** Lets pending promise callbacks run. */
const settle = async () => {
  for (let i = 0; i < 20; i++) await Promise.resolve();
};

/** Drives the sidecar like a client: requests get ids, replies are collected. */
function client(sdk: CursorSdk) {
  const out: Array<Record<string, unknown>> = [];
  const acp = makeCursorAcp({ sdk, mode: "full-access", write: (m) => out.push(m as never) });
  let id = 0;
  const call = async (method: string, params: object = {}) => {
    const mine = ++id;
    await acp.receive({ id: mine, method, params: params as Record<string, unknown> });
    return out.find((m) => m.id === mine) as { result?: any; error?: any };
  };
  return { acp, out, call };
}

describe("Cursor over ACP", () => {
  it("asks for a sign-in, signs in through a URL the client opens, then opens sessions", async () => {
    const { sdk, finishLogin } = fakeSdk([]);
    const { acp, out, call } = client(sdk);

    const init = await call("initialize");
    expect(init.result.authMethods).toEqual([expect.objectContaining({ id: "cursor-login" })]);
    expect((await call("session/new", { cwd: "/work" })).error.code).toBe(-32000);

    const signingIn = acp.receive({ id: 100, method: "authenticate", params: {} });
    await settle();
    const elicitation = out.find((m) => m.method === "elicitation/create") as any;
    expect(elicitation.params).toMatchObject({ mode: "url", url: "https://cursor.test/login" });
    await acp.receive({ id: elicitation.id, result: { action: "accept" } });
    finishLogin();
    await signingIn;
    expect(out.find((m) => m.id === 100)).toMatchObject({ result: {} });

    const session = await call("session/new", { cwd: "/work" });
    expect(session.result.sessionId).toBe("agent-1");
    expect(session.result.configOptions[0].options).toEqual([
      { value: "default", name: "Auto" },
      { value: "gpt-9", name: "GPT 9" },
    ]);
  });

  it("streams a run as messages and tool calls, split around each tool", async () => {
    const shell = { type: "shell", args: { command: "ls" } };
    const { sdk, sent } = fakeSdk([
      { type: "text-delta", text: "Let me look." },
      { type: "tool-call-started", callId: "c1", toolCall: shell },
      {
        type: "tool-call-completed",
        callId: "c1",
        toolCall: {
          ...shell,
          result: { status: "success", value: { stdout: "a.txt", stderr: "" } },
        },
      },
      { type: "text-delta", text: "Found a.txt." },
    ] as unknown as ReadonlyArray<InteractionUpdate>);
    await sdk.store.save(credentials);
    const { out, call } = client(sdk);
    await call("session/new", { cwd: "/work" });
    await call("session/set_config_option", {
      sessionId: "agent-1",
      configId: "model",
      value: "gpt-9",
    });

    const reply = await call("session/prompt", {
      sessionId: "agent-1",
      prompt: [{ type: "text", text: "list files" }],
    });

    expect(reply.result).toEqual({ stopReason: "end_turn" });
    expect(sent[0]).toMatchObject({ message: "list files", options: { model: { id: "gpt-9" } } });
    const updates = out
      .filter((m) => m.method === "session/update")
      .map((m: any) => m.params.update);
    expect(updates.map((u) => [u.sessionUpdate, u.messageId ?? u.toolCallId])).toEqual([
      ["agent_message_chunk", "segment-1"],
      ["tool_call", "c1"],
      ["tool_call_update", "c1"],
      ["agent_message_chunk", "segment-3"],
    ]);
    expect(updates[2]).toMatchObject({
      status: "completed",
      kind: "execute",
      rawInput: { command: "ls" },
      content: [{ type: "content", content: { type: "text", text: "a.txt" } }],
    });
  });

  it("cancels a running prompt", async () => {
    const { sdk } = fakeSdk([]);
    await sdk.store.save(credentials);
    const { acp, out, call } = client(sdk);
    await call("session/new", { cwd: "/work" });

    const running = acp.receive({
      id: 50,
      method: "session/prompt",
      params: { sessionId: "agent-1", prompt: [{ type: "text", text: "wait here" }] },
    });
    await settle();
    await acp.receive({ method: "session/cancel", params: { sessionId: "agent-1" } });
    await running;
    expect(out.find((m) => m.id === 50)).toMatchObject({ result: { stopReason: "cancelled" } });
  });
});
