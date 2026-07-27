import { spawn } from "node:child_process";

function pluginContext() {
  try {
    return JSON.parse(process.env.HERDR_PLUGIN_CONTEXT_JSON ?? "{}");
  } catch {
    return {};
  }
}

function firstString(value, keys) {
  if (!value || typeof value !== "object") return null;
  for (const key of keys) {
    if (typeof value[key] === "string" && value[key].length > 0) return value[key];
  }
  for (const nested of Object.values(value)) {
    const found = firstString(nested, keys);
    if (found) return found;
  }
  return null;
}

export function resolveWorkspaceCwd(context = pluginContext()) {
  return firstString(context, ["workspace_cwd", "checkout_path", "foreground_cwd", "cwd"]);
}

export function launcherCommand(entrypoint) {
  if (entrypoint === "server") return ["t3", ["serve", "--no-browser"]];
  if (entrypoint === "dashboard") return ["t3", ["tui", "--tui-host", "herdr"]];
  throw new Error(`Unknown T3 Code plugin entrypoint: ${entrypoint}`);
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const [command, args] = launcherCommand(process.argv[2] ?? "");
  const cwd = resolveWorkspaceCwd() ?? process.cwd();
  const child = spawn(command, args, {
    cwd,
    env: process.env,
    stdio: "inherit",
  });
  child.once("error", (error) => {
    process.stderr.write(
      error.code === "ENOENT"
        ? "T3 Code is not installed. Install the `t3` CLI and reopen this plugin pane.\n"
        : `Could not start T3 Code: ${error.message}\n`,
    );
    process.exitCode = 1;
  });
  child.once("exit", (code, signal) => {
    if (signal) {
      process.kill(process.pid, signal);
      return;
    }
    process.exitCode = code ?? 1;
  });
}
