import { createHerdrTuiHost, standaloneTuiHost, type TuiHost } from "./host.ts";

export function tuiHostFromEnvironment(
  environment: Readonly<Record<string, string | undefined>>,
  environmentKey: string,
  workspaceCwd = process.cwd(),
): TuiHost {
  if (environment.T3_TUI_HOST !== "herdr") return standaloneTuiHost;
  const socketPath = environment.HERDR_SOCKET_PATH;
  const paneId = environment.HERDR_PANE_ID;
  const workspaceId = environment.HERDR_WORKSPACE_ID;
  if (!socketPath || !paneId || !workspaceId) {
    throw new Error(
      "Herdr host mode requires HERDR_SOCKET_PATH, HERDR_PANE_ID, and HERDR_WORKSPACE_ID.",
    );
  }
  return createHerdrTuiHost({
    socketPath,
    paneId,
    workspaceId,
    workspaceCwd,
    environmentKey,
    ...(environment.HERDR_PLUGIN_ID ? { pluginId: environment.HERDR_PLUGIN_ID } : {}),
    ...(environment.HERDR_PLUGIN_STATE_DIR
      ? { stateDirectory: environment.HERDR_PLUGIN_STATE_DIR }
      : {}),
  });
}
