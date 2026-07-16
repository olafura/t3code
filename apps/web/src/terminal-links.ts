export * from "@t3tools/shared/terminalLinks";

import {
  formatFilePathPosition,
  splitFilePathPosition,
} from "@t3tools/client-runtime/markdown-links";
import { resolveTerminalPath } from "@t3tools/shared/terminalLinks";

import { isMacPlatform } from "./lib/utils";

export function isTerminalLinkActivation(
  event: Pick<MouseEvent, "metaKey" | "ctrlKey">,
  platform = typeof navigator === "undefined" ? "" : navigator.platform,
): boolean {
  if (platform.length === 0) return false;
  return isMacPlatform(platform)
    ? event.metaKey && !event.ctrlKey
    : event.ctrlKey && !event.metaKey;
}

export function resolvePathLinkTarget(rawPath: string, cwd: string): string {
  const position = splitFilePathPosition(rawPath);
  return formatFilePathPosition({ ...position, path: resolveTerminalPath(position.path, cwd) });
}
