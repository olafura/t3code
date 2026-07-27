import { spawn } from "node:child_process";
import { existsSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const launcherPath = fileURLToPath(import.meta.url);
const repositoryRoot = resolve(dirname(launcherPath), "../..");

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

export function launcherCommand(
  entrypoint,
  {
    executable = process.env.T3_CODE_BIN,
    devUrl = process.env.T3_CODE_DEV_URL ?? "http://localhost:5733",
    root = repositoryRoot,
    fileExists = existsSync,
  } = {},
) {
  const args =
    entrypoint === "server"
      ? ["serve", "--no-browser"]
      : entrypoint === "dashboard"
        ? ["tui", "--tui-host", "herdr"]
        : null;
  if (!args) {
    throw new Error(`Unknown T3 Code plugin entrypoint: ${entrypoint}`);
  }

  if (executable) return [executable, args];

  const sourceCli = resolve(root, "apps/server/src/bin.ts");
  if (fileExists(sourceCli)) {
    const sourceArgs = entrypoint === "dashboard" ? [...args, "--dev-url", devUrl] : args;
    return [process.execPath, [sourceCli, ...sourceArgs]];
  }

  return ["t3", args];
}

export function isMainModule(argvEntry = process.argv[1], cwd = process.cwd()) {
  return typeof argvEntry === "string" && resolve(cwd, argvEntry) === launcherPath;
}

if (isMainModule()) {
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
