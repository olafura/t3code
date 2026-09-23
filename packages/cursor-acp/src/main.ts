#!/usr/bin/env node
// @effect-diagnostics globalConsole:off - a plain stdio process; stderr is its log.
// Cursor over ACP on stdio, for T3 nodes (`T3.Acp`). Usage: main.ts [--mode <runtime mode>]
//
// T3_CURSOR_CREDENTIALS is where the Cursor sign-in is kept; CURSOR_API_KEY replaces it.
import * as NodeReadline from "node:readline";

import {
  Agent,
  AuthenticationError,
  Cursor,
  CursorSdkError,
  FileCredentialStore,
} from "@cursor/sdk";

import { makeCursorAcp, type RuntimeMode } from "./agent.ts";

// Stdout carries protocol frames only; anything the SDK logs goes to stderr.
console.log = console.error;
console.info = console.error;

const modeIndex = process.argv.indexOf("--mode");
const mode = (modeIndex >= 0 ? process.argv[modeIndex + 1] : "approval-required") as RuntimeMode;

const acp = makeCursorAcp({
  mode,
  write: (message) => process.stdout.write(`${JSON.stringify(message)}\n`),
  sdk: {
    version: "1.0.31",
    store: new FileCredentialStore(process.env.T3_CURSOR_CREDENTIALS || undefined),
    envApiKey: process.env.CURSOR_API_KEY?.trim() || undefined,
    createAgent: (options) => Agent.create(options),
    resumeAgent: (agentId, options) => Agent.resume(agentId, options),
    listModels: (apiKey) => Cursor.models.list({ apiKey }),
    login: (options) =>
      Cursor.auth.login({ ...options, openBrowser: false, apiKeyName: "T3 Code" }),
    isAuthError: (cause) =>
      cause instanceof AuthenticationError ||
      (cause instanceof CursorSdkError && cause.status === 401),
  },
});

const lines = NodeReadline.createInterface({ input: process.stdin });
lines.on("line", (line) => {
  if (line.trim() === "") return;
  try {
    void acp.receive(JSON.parse(line));
  } catch (cause) {
    console.error("cursor-acp: unreadable frame", cause);
  }
});
lines.on("close", () => process.exit(0));
