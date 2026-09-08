import type { EnvironmentThreadShell } from "@t3tools/client-runtime/state/models";
import { useEffect, useRef } from "react";

import { createDesktopNotificationTracker } from "./shellDesktopNotifications";

/** Publishes small live batches independently of the sidebar's selected project or row limit. */
export function useShellDesktopNotifications(threads: ReadonlyArray<EnvironmentThreadShell>) {
  const tracker = useRef<ReturnType<typeof createDesktopNotificationTracker> | null>(null);
  useEffect(() => {
    tracker.current ??= createDesktopNotificationTracker();
    const events = tracker.current(threads);
    if (events.length > 0) {
      void window.t3Shell?.publish("desktopNotifications", events);
    }
  }, [threads]);
}
