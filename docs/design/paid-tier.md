# Paid tier: Learnfold Plus and Learnfold Hosted

Status: implemented on branch `worktree-agent-a5a0ee0f0ba656b66`, not yet released. Written before the code; kept in sync with it.

## What exists today (exploration)

- There is no StoreKit code and no tip jar in the repo. This is the first purchase surface.
- Agents are `CourseAgentProvider` ids: `hosted`, `apple-on-device`, `apple-private-cloud`, and app-server runtimes (`codex`, `hermes`). BYOK and custom provider endpoints are configured under Codex (`OpenAIApiKeyStore`), so they are the `codex` runtime.
- Hosted = `services/hosted-agent` (Cloudflare Worker + Think Durable Object, Muse model). The iOS side is `SystemHostedCourseAgentRuntime`. A free "guest" identity (random 256-bit secret in iCloud Keychain, `HostedGuestIdentity`) is exchanged by Rust (`HostedAgentClient::guest`) at `POST /guest-session` for a one-hour session-bound token. The Worker caps 60 turns per guest and 1000 global per UTC day.
- Every course turn funnels through three `CourseExperienceStore` entry points that reach `forwardToAgent`: `sendMessage`, `retryRecoveredSubmission`, `generateCourseNodeInBackground`. Agent selection goes through `connectLocalAgent`.

## What gates what

| Agent | Plan needed | Enforced by |
|---|---|---|
| Apple on-device, Apple Private Cloud Compute | none (free) | n/a |
| Hosted | Hosted ($5/mo) | Worker (authoritative) plus a client gate for UX |
| Codex (incl. BYOK / custom endpoint), Hermes, any other non-Hosted runtime | Plus ($1/mo) or Hosted | client only |

Hosted includes Plus. Both products live in one subscription group (`Learnfold Plans`) with Hosted at level 1, so Plus to Hosted is an upgrade and the reverse is a downgrade.

Plus can only be enforced on the device: those runtimes never touch Learnfold servers. A jailbroken or patched client can skip it. That is acceptable for a $1 convenience tier; Hosted costs real money per turn, so it is the one enforced server-side.

## Where entitlement state lives

- Source of truth is StoreKit 2. `SubscriptionStore` (`@MainActor @Observable`) reads `Transaction.currentEntitlements`, keeps only `.verified` results (StoreKit verifies the JWS locally), drops revoked and non-auto-renewable ones, and refreshes on launch, after purchase and restore, and on every `Transaction.updates` element (renewals, Ask to Buy approvals, refunds, other devices).
- It is not persisted by us. StoreKit caches entitlements on device, so cold start offline still works.
- `SubscriptionBackend` is the StoreKit seam; tests inject a fake. `AgentAccessPolicy` is the pure agent-to-plan mapping.
- `CourseExperienceStore` takes an optional `EntitlementProviding` plus an `enforcesEntitlements` flag (default off, so tests and tools are untouched). When a gated send/selection is attempted it sets `paywallRequest`, and `ContentView` presents `SubscriptionPaywallView`. A paywall shown before entitlements finished loading dismisses itself once the entitlement appears.
- Enforcement is a build flag: `LEARNFOLD_SUBSCRIPTIONS_ENFORCED` (Info.plist, `NO` in Debug, `YES` in Release; the environment variable of the same name overrides it). The notarized direct-distribution Mac build is never gated.
- Launch-time auto-reconnect (`gatesEntitlement: false`) never opens a paywall; the first send does.

## Server verification (Hosted)

1. The app asks StoreKit for its freshest Hosted transaction (`VerificationResult.jwsRepresentation`) and POSTs it to the existing exchange: `POST /guest-session?sessionId=...`, `Authorization: Guest <secret>`, body `{"signedTransaction": "<JWS>"}`.
2. `services/hosted-agent/src/app-store.ts` verifies offline, never calling Apple: x5c chain ends in the pinned Apple Root CA - G3 (fingerprint pinned in code and tested), each certificate is signed by the next (ECDSA P-256/P-384 via WebCrypto) and valid at the signing date, leaf and intermediate carry Apple's marker OIDs, ES256 signature verifies under the leaf, `bundleId`, product id, type, no `revocationDate`, `expiresDate` (plus grace) in the future, environment is Production or (configurably) Sandbox. Xcode-environment transactions never verify.
3. On success the Worker stores `entitlement:<hash(guest secret)>` = `{originalTransactionId, validUntil = min(expiresDate + grace, now + 24h)}` in the `GuestUsage` Durable Object, binds the guest to `subscription:<originalTransactionId>` (max 3 guests), and mints the normal guest token. The token format is unchanged, so conversation history and the guest namespace are preserved across the free to paid transition.
4. `enforceGuestTurnLimit` runs on every turn and continuation. An entitled guest consumes the paid budget (per subscription, default 150/day, own global budget). An unentitled guest consumes the free budget, or is refused when `REQUIRE_SUBSCRIPTION=true`.
5. Transport: Swift performs this one exchange itself (`HostedSubscriptionExchange`) and hands the resulting bearer token to `HostedAgentClient(baseUrl:accessToken:)`. This avoided changing the shared UniFFI surface, which would also change the Kotlin bindings. Unsubscribed guests still use the Rust guest exchange unchanged. See "Follow-ups".

## Restore, renewal, grace, refund

- Restore: `AppStore.sync()` then re-read entitlements. Exposed in the paywall and Settings > Plan.
- Renewal: `Transaction.updates` refreshes the client; the next token exchange (each connect, at most hourly) re-presents the newer transaction, which extends the server entitlement.
- Billing grace: StoreKit keeps a grace-period subscription in `currentEntitlements`. The Worker cannot see Apple's state without the App Store Server API, so it accepts a lapsed `expiresDate` for `SUBSCRIPTION_GRACE_SECONDS` (default 3 days).
- Refund/revocation: StoreKit drops the transaction on the client immediately; a revoked JWS fails server verification. The server entitlement lasts at most 24 hours past the last good exchange. Faster revocation needs App Store Server Notifications V2 (not built).
- Offline: Plus works offline from StoreKit's local cache. Hosted needs the network anyway.

## Free-user transition

- Server flag `REQUIRE_SUBSCRIPTION` defaults to `false`: nothing changes for existing users until the owner flips it. Order of rollout: ship the app with enforcement, wait for adoption, then flip the flag. While it is `false`, a verified transaction simply raises the daily budget.
- The client gate ships with the build, so existing Hosted users on the new build see the paywall at their next Hosted send even before the Worker flag flips. This is a product decision; see the report.
- Existing conversations and courses are never deleted or locked: gating only blocks new turns. Reading courses stays free.
- New learners are not defaulted into a gated agent (`preferredSetupAgentID` skips gated ones).

## Privacy implications

The Hosted receipt ties a subscription to the anonymous guest identity: the Worker stores `hash(guest secret)`, `originalTransactionId`, expiry and counters. No Apple ID, name or payment data. `privacy.html` and `terms.html` describe this. Because the guest secret syncs via iCloud Keychain, the same subscriber reaches the same Hosted history across their devices.

## Tests

- Worker: vitest with a throwaway test PKI (`test/fixtures/generate-apple-chain.sh`) covering chain, signature, bundle, product, revocation, expiry/grace, environment, tampering, per-subscription budget, guest binding, and the REQUIRE_SUBSCRIPTION modes.
- iOS: XCTest for plan rules, the policy, `SubscriptionStore` against a fake backend, the store's gate, and the Hosted exchange against a stub `URLProtocol`.

## Follow-ups (not done)

- Move the token exchange into Rust (`HostedAgentClient::guest_with_transaction`) to match the repo's "protocol in Rust" rule once a Rust rebuild is acceptable.
- App Store Server Notifications V2 for immediate refund/expiry handling.
- A yearly plan (add the product id to `HOSTED_PRODUCT_IDS`).
