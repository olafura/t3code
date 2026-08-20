#!/usr/bin/env node

import * as NodeRuntime from "@effect/platform-node/NodeRuntime";
import * as NodeServices from "@effect/platform-node/NodeServices";
import * as Console from "effect/Console";
import * as Effect from "effect/Effect";
import { Command, Flag } from "effect/unstable/cli";

import { exportThread } from "./thread-transfer.ts";

export const exportThreadCommand = Command.make(
  "export-thread",
  {
    source: Flag.string("source").pipe(
      Flag.withDescription("Workspace root containing .t3, or an explicit .t3 directory."),
    ),
    threadId: Flag.string("thread-id"),
    output: Flag.string("output").pipe(Flag.withDescription("Archive JSON file to create.")),
  },
  ({ source, threadId, output }) =>
    Effect.gen(function* () {
      const result = yield* exportThread({ source, threadId, output });
      yield* Console.log(
        `Exported '${result.title}' (${result.threadId}, orchestrator v${result.orchestrationVersion}) to ${result.output}`,
      );
      yield* Console.log(`  ${result.eventCount} events, ${result.attachmentCount} attachments`);
    }),
).pipe(Command.withDescription("Export one T3 thread and its image attachments."));

if (import.meta.main) {
  Command.run(exportThreadCommand, { version: "0.0.0" }).pipe(
    Effect.provide(NodeServices.layer),
    NodeRuntime.runMain,
  );
}
