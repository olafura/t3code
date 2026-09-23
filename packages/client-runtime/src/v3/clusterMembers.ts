import * as Duration from "effect/Duration";
import * as Effect from "effect/Effect";
import * as Option from "effect/Option";
import * as Schema from "effect/Schema";
import * as Stream from "effect/Stream";
import * as SubscriptionRef from "effect/SubscriptionRef";

import { BearerConnectionCredential, BearerConnectionProfile } from "../connection/catalog.ts";
import * as ConnectionCredentialStore from "../connection/credentialStore.ts";
import { clusterRegistrations } from "../connection/onboarding.ts";
import * as EnvironmentRegistry from "../connection/registry.ts";
import { fetchRemoteEnvironmentDescriptor } from "../environment/descriptor.ts";

const isBearerProfile = Schema.is(BearerConnectionProfile);
const isBearerCredential = Schema.is(BearerConnectionCredential);
const RESYNC_INTERVAL = Duration.minutes(1);

/**
 * Registers machines that joined a protocol-3 cluster after it was paired.
 *
 * Pairing registers the cluster as it was then. This re-reads the descriptor of
 * each saved bearer environment (once per node address) whenever the saved
 * environments change and every minute, and registers members it has not seen,
 * reached through the same node with the same credential. Nothing is removed: a
 * member that left stays until the user removes it, like any environment.
 */
export const syncClusterMembers = Effect.gen(function* () {
  const registry = yield* EnvironmentRegistry.EnvironmentRegistry;
  const credentials = yield* ConnectionCredentialStore.ConnectionCredentialStore;

  const syncOnce = Effect.gen(function* () {
    const entries = yield* SubscriptionRef.get(registry.entries);
    const byAddress = new Map<string, BearerConnectionProfile>();
    for (const entry of entries.values()) {
      const profile = Option.getOrUndefined(entry.profile);
      if (entry.enabled && profile !== undefined && isBearerProfile(profile))
        byAddress.set(profile.httpBaseUrl, profile);
    }

    for (const profile of byAddress.values()) {
      const credential = Option.getOrUndefined(yield* credentials.get(profile.connectionId));
      if (credential === undefined || !isBearerCredential(credential)) continue;
      const descriptor = yield* fetchRemoteEnvironmentDescriptor({
        httpBaseUrl: profile.httpBaseUrl,
      }).pipe(Effect.option);
      if (Option.isNone(descriptor)) continue;
      for (const member of clusterRegistrations(descriptor.value, profile, credential)) {
        if (!entries.has(member.target.environmentId)) yield* registry.register(member);
      }
    }
  }).pipe(Effect.ignore);

  yield* Stream.merge(
    SubscriptionRef.changes(registry.entries).pipe(Stream.map(() => undefined)),
    Stream.tick(RESYNC_INTERVAL),
  ).pipe(
    Stream.debounce(Duration.seconds(1)),
    Stream.runForEach(() => syncOnce),
  );
});
