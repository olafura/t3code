import * as NodeFS from "node:fs";
import * as NodeUtil from "node:util";

/** Preserve console errors that OpenTUI otherwise only displays in its overlay. */
export function captureTuiConsole(
  logPath: string,
  target: Pick<Console, "error" | "warn"> = console,
) {
  const originalError = target.error;
  const originalWarn = target.warn;
  const capture =
    (level: "error" | "warn", original: typeof console.error) =>
    (...args: Parameters<typeof console.error>) => {
      try {
        NodeFS.appendFileSync(
          logPath,
          `[${new Date().toISOString()}] ${level}: ${NodeUtil.format(...args)}\n`,
        );
      } catch {
        // A diagnostic must not prevent the original error from being displayed.
      }
      original.apply(target, args);
    };
  target.error = capture("error", originalError);
  target.warn = capture("warn", originalWarn);
  return () => {
    target.error = originalError;
    target.warn = originalWarn;
  };
}
