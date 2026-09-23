import { createDeviceEnvironmentAtoms } from "@t3tools/client-runtime/state/device";
import {
  atDeviceHubBasePath,
  resolveDeviceHubAccess,
} from "@t3tools/client-runtime/state/deviceHubAccess";
import type { EnvironmentId } from "@t3tools/contracts";
import * as Effect from "effect/Effect";
import * as Option from "effect/Option";
import { Atom } from "effect/unstable/reactivity";
import { useMemo } from "react";

import { connectionAtomRuntime } from "../connection/runtime";
import { appAtomRegistry } from "./atom-registry";
import { useEnvironmentQuery } from "./query";
import { environmentSession, usePreparedConnection } from "./session";

export const deviceEnvironment = createDeviceEnvironmentAtoms(connectionAtomRuntime);

const deviceHubAccessAtom = Atom.family((environmentId: EnvironmentId) =>
  connectionAtomRuntime
    .atom((get) => {
      const prepared = Option.getOrNull(
        get(environmentSession.preparedConnectionValueAtom(environmentId)),
      );
      return prepared === null
        ? Effect.never
        : resolveDeviceHubAccess({ prepared, hubBasePath: "/api/device-hub" });
    })
    .pipe(Atom.setIdleTTL(60_000), Atom.withLabel(`mobile-device-hub-access:${environmentId}`)),
);

export function refreshDeviceHubAccess(environmentId: EnvironmentId) {
  appAtomRegistry.refresh(deviceHubAccessAtom(environmentId));
}

export function useDeviceHubAccess(environmentId: EnvironmentId, hostId: string) {
  const prepared = usePreparedConnection(environmentId);
  const query = useEnvironmentQuery(deviceHubAccessAtom(environmentId));
  const hubBasePath = useEnvironmentQuery(deviceEnvironment.state({ environmentId, input: {} }))
    .data?.hubBasePath;
  const access = useMemo(
    () =>
      query.data && query.error === null && Option.isSome(prepared)
        ? {
            ...atDeviceHubBasePath(query.data, hubBasePath),
            query: { ...query.data.query, hostId },
          }
        : null,
    [query.data, query.error, prepared, hostId, hubBasePath],
  );
  return { access, error: query.error, refresh: query.refresh };
}
