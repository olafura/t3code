// Writes the Node server's MCP tool definitions to priv/mcp_tools.json, so Elixir
// nodes advertise the same tools with the same descriptions and input schemas.
// Run from the repo root: node apps/server-ex/scripts/export-mcp-tools.ts
import * as NodeFs from "node:fs";
import * as NodeModule from "node:module";
import * as NodePath from "node:path";
import * as NodeUrl from "node:url";

// The tool definitions and their `effect` live with the Node server.
const serverRoot = NodePath.join(import.meta.dirname, "..", "..", "server");
const serverRequire = NodeModule.createRequire(NodePath.join(serverRoot, "package.json"));
const { Tool } = (await import(
  NodeUrl.pathToFileURL(serverRequire.resolve("effect/unstable/ai")).href
)) as typeof import("effect/unstable/ai");

const toolkits = [
  "attachment",
  "environment",
  "orchestrator",
  "preview",
  "previewControls",
  "project",
  "pullRequests",
  "thread",
  "worktree",
];

const tools: Array<{ name: string; description: string; inputSchema: unknown }> = [];
for (const name of toolkits) {
  const module = await import(`../../server/src/mcp/toolkits/${name}/tools.ts`);
  for (const [exportName, value] of Object.entries(module)) {
    if (!exportName.endsWith("Toolkit") || value == null || !("tools" in (value as object)))
      continue;
    for (const tool of Object.values((value as { tools: Record<string, any> }).tools)) {
      if (tools.some((known) => known.name === tool.name)) continue;
      tools.push({
        name: tool.name,
        description: tool.description ?? "",
        inputSchema: Tool.getJsonSchema(tool),
      });
    }
  }
}

tools.sort((a, b) => a.name.localeCompare(b.name));
const priv = NodePath.join(import.meta.dirname, "..", "priv");
NodeFs.mkdirSync(priv, { recursive: true });
NodeFs.writeFileSync(NodePath.join(priv, "mcp_tools.json"), JSON.stringify(tools, null, 2) + "\n");

// What agents are told about the tools. Node's ACP terminal fallback names a Node
// entrypoint nodes do not have, so that paragraph stays out.
const { T3_CODE_ORCHESTRATION_INSTRUCTIONS } =
  await import("../../server/src/provider/T3OrchestrationInstructions.ts");
const instructions = (T3_CODE_ORCHESTRATION_INSTRUCTIONS as string)
  .split("\n\n")
  .filter((paragraph) => !paragraph.startsWith("ACP fallback:"))
  .join("\n\n")
  .trim();
NodeFs.writeFileSync(NodePath.join(priv, "mcp_instructions.md"), instructions + "\n");
console.log(`${tools.length} tools and the instructions -> ${priv}`);
