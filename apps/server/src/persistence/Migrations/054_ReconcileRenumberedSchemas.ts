import * as Effect from "effect/Effect";

import AuthSessionClientConnection from "./041_AuthSessionClientConnection.ts";
import ProjectionThreadLinkedPullRequest from "./042_ProjectionThreadLinkedPullRequest.ts";
import ProjectionThreadsUnsettledAt from "./043_ProjectionThreadsUnsettledAt.ts";
import ClearAutomaticProjectModelDefaults from "./044_ClearAutomaticProjectModelDefaults.ts";

/**
 * Re-applies migrations that a database migrated under the pre-rebase
 * numbering recorded by id but never ran. Every step is idempotent, so a
 * fresh database passes through unchanged.
 */
export default Effect.gen(function* () {
  yield* AuthSessionClientConnection;
  yield* ProjectionThreadLinkedPullRequest;
  yield* ProjectionThreadsUnsettledAt;
  yield* ClearAutomaticProjectModelDefaults;
});
