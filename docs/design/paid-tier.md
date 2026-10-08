# Paid tier: Learnfold Plus and Learnfold Hosted (RevenueCat)

Status: implemented on branch `revenuecat-subscriptions`, not yet released. Supersedes the native StoreKit 2 + Apple-JWS design from `paid-tier-subscriptions`; the product and UX decisions are unchanged, the payments layer is RevenueCat.

## What exists today (exploration)

- Agents are `CourseAgentProvider` ids: `hosted`, `apple-on-device`, `apple-private-cloud`, and app-server runtimes (`codex`, `hermes`). BYOK and custom provider endpoints are configured under Codex (`OpenAIApiKeyStore`), so they are the `codex` runtime.
- Hosted = `services/hosted-agent` (Cloudflare Worker + Think Durable Object, Muse model). The iOS side is `SystemHostedCourseAgentRuntime`. A free "guest" identity (random 256-bit secret in iCloud Keychain, `HostedGuestIdentity`) is exchanged by Rust (`HostedAgentClient::guest`) at `POST /guest-session` for a one-hour session-bound token. The Worker caps 60 turns per guest and 1000 global per UTC day on the free path.
- Every course turn funnels through three `CourseExperienceStore` entry points that reach `forwardToAgent`: `sendMessage`, `retryRecoveredSubmission`, `generateCourseNodeInBackground`. Agent selection goes through `connectLocalAgent`.

## What gates what

| Agent | Plan needed | Enforced by |
|---|---|---|
| Apple on-device, Apple Private Cloud Compute | none (free) | n/a |
| Hosted | Hosted ($5/mo) | Worker (authoritative) plus a client gate for UX |
| Codex (incl. BYOK / custom endpoint), Hermes, any other non-Hosted runtime | Plus ($1/mo) or Hosted | client only |

Hosted includes Plus. Both products live in one App Store subscription group (`Learnfold Plans`) with Hosted at level 1, so Plus to Hosted is an upgrade and the reverse is a downgrade. Product ids: `com.chirag.learnfold.plus.monthly`, `com.chirag.learnfold.hosted.monthly`. Prices are never in code or copy; they come from the store as localized strings.

Plus can only be enforced on the device: those runtimes never touch Learnfold servers. A jailbroken or patched client can skip it. That is acceptable for a $1 convenience tier; Hosted costs real money per turn, so it is the one enforced server-side.

## RevenueCat model

| Thing | Value |
|---|---|
| Entitlements | `plus`, `hosted` (identifiers equal `LearnfoldPlan.rawValue`). Attach the Hosted product to both entitlements in the dashboard; the app also treats `hosted` as including `plus` on its own, so a dashboard slip cannot lock out a Hosted subscriber. |
| Offering | one default (`current`) offering with two packages, one per product |
| SDK | `purchases-ios` 5.93.0, SPM, pinned exactly in `apps/ios/project.yml`, linked into the iOS app only |
| Public SDK key | `LEARNFOLD_REVENUECAT_API_KEY` build setting -> `LearnfoldRevenueCatApiKey` Info.plist key. Empty in source. The environment variable of the same name overrides it for local runs. A key starting with `sk_` (a secret key) is refused. |
| Secret key | Worker secret `REVENUECAT_SECRET_API_KEY`. Never in the app or the repo. |

## Identity: the app user ID

RevenueCat needs a stable user id, and the Worker needs to find a subscriber with no account system. Both come from the Hosted guest identity.

```
appUserID = "lf1_" + hex(SHA-256("learnfold.revenuecat.app-user.v1:" + guestSecret))
```

- `guestSecret` is the 256-bit hex secret already kept in iCloud Keychain (`HostedGuestIdentity`) and presented by the app as `Authorization: Guest <secret>` at `POST /guest-session`.
- It is one-way and domain separated. RevenueCat (a third party) never sees the secret, and never sees `guest-<sha256(secret)>`, the namespace the Worker uses for conversation history.
- Swift: `HostedGuestIdentity.revenueCatAppUserID(secret:)`. Worker: `revenueCatAppUserId()` in `src/revenuecat.ts`. A shared test vector (`secret = "0123456789abcdef" x 4` -> `lf1_66f345ab...0756`) is asserted by both test suites, so they cannot drift apart silently.
- Why a client cannot claim someone else's entitlement: the app sends no ID and no proof of purchase. The Worker derives the ID from the secret that authenticates the request. Without the secret there is no way to name another subscriber's ID, and the 256-bit secret is not guessable.
- Sync: the secret syncs through iCloud Keychain, so a subscriber's other devices derive the same ID and see the same plan with no sign-in.

When the SDK is configured:

- If the install already has a Hosted guest identity, `Purchases.configure(appUserID:)` uses the derived ID. Reading it uses `HostedGuestIdentity.existingIdentity`, which never creates or writes anything, so launching cannot race iCloud Keychain into minting a second identity on a fresh device.
- Otherwise the SDK starts anonymous (`$RCAnonymousID`). Whenever an identity exists later (every refresh checks), the backend calls `logIn(derivedID)`, which merges anonymous purchases into it. Before a Hosted purchase the identity is created if missing, so the purchase always lands on the ID the Worker looks up.
- Known limitation: a conversation bound to an older identity (`ownerSubject`) on a second device uses that identity's secret at the Worker, which may differ from the secret the SDK logged in with. That only happens for users who ended up with two identities before iCloud Keychain converged; they would see Hosted as unsubscribed on that conversation and can fix it with Restore Purchases (RevenueCat transfers the purchase to the current ID). Not worth extra moving parts.
- `automaticDeviceIdentifierCollectionEnabled` is off: the app ID is already a pseudonym, so the SDK sends neither IDFV nor IDFA.

## Where entitlement state lives (client)

- `SubscriptionStore` (`@MainActor @Observable`) is unchanged in shape. It sits on `SubscriptionBackend`, the seam the paywall, `AgentAccessPolicy` gating and tests already use. `HeldEntitlement` no longer carries a signed transaction.
- Backends: `RevenueCatSubscriptionBackend` (production), `UnavailableSubscriptionBackend` (no key), `StoreKitSubscriptionBackend` (DEBUG only, local `Support/Learnfold.storekit`), `FixtureSubscriptionBackend` (DEBUG UI tests only). `SubscriptionBackendFactory.live()` picks one.
- The RevenueCat backend reads `CustomerInfo.entitlements.active["plus"|"hosted"]`, refreshes on launch, after purchase and restore, and on every `customerInfoStream` element (renewals, Ask to Buy approvals, other devices, refunds). Offers come from the current offering's packages; the displayed name, price and period are the store product's localized values. If a refresh fails (offline), the last confirmed entitlements stay in place rather than revoking access.
- Enforcement is a build flag: `LEARNFOLD_SUBSCRIPTIONS_ENFORCED` (Info.plist, `NO` in Debug, `YES` in Release; the environment variable overrides it). The notarized direct-distribution Mac build is never gated, and the Mac Catalyst target does not link RevenueCat.
- A build that cannot sell (no SDK key) is never enforced: `ContentView` passes `enforces && store.purchasesAvailable`. This is fail-open on purpose. A Release build shipped without the key must not lock people out of every non-Apple agent behind a paywall nobody can complete. The paywall in such a build says "Purchases are unavailable right now" and disables Subscribe. The release checklist makes the key a required step.
- Launch-time auto-reconnect (`gatesEntitlement: false`) never opens a paywall; the first send does.

## First run and App Review

- The bundled practice course is app-authored and needs no agent turn, but `installStarterCourseIfNeeded()` requires `setupComplete`, i.e. a chosen agent. Previously, in an enforced build, a learner without a plan and without Apple Intelligence (a reviewer's device or simulator) hit the paywall at setup selection and saw nothing else.
- Now `connectLocalAgent` does not paywall first-run setup (`hadCompletedSetup == false`). Hosted setup is purely local, so choosing it completes setup, shows the library and the practice course, and the first send is what opens the Hosted paywall. Switching agents after setup is still gated at selection, and every send path is still gated. There is no hard block in front of the app.
- Apple on-device and Private Cloud Compute remain free and are preferred by `preferredSetupAgentID` whenever available.

## Server verification (Hosted)

1. The app opens a Hosted session as before: Rust performs `POST /guest-session?sessionId=...` with `Authorization: Guest <secret>`. No Swift exchange and no request body; the Rust client is unchanged.
2. `services/hosted-agent/src/guest.ts` derives the app user ID from the secret and calls `GET https://api.revenuecat.com/v1/subscribers/{id}` with the secret key. The `hosted` entitlement is active if `expires_date` is in the future, or its `grace_period_expires_date` is, or `expires_date` is null (non-expiring grants such as a promotional entitlement for an App Review account). Refunded subscriptions are rejected. Sandbox is accepted unless `ACCEPT_SANDBOX_TRANSACTIONS=false` (default true; App Review and TestFlight purchase in Sandbox).
3. The answer is cached per guest in the `GuestUsage` Durable Object (`entitlement:<hash>`): at most 15 minutes for a subscriber, 60 seconds for a guest without the entitlement (so a fresh purchase is noticed fast). Each turn and continuation re-checks a stale subscriber entry with RevenueCat, so a long-lived connection cannot outlive a lapsed subscription by more than one cache window.
4. `enforceGuestTurnLimit`: an entitled guest consumes the paid budget (`turns:sub:<original_app_user_id>`, default 150/day, own global budget). An unentitled guest consumes the free budget, or is refused when `REQUIRE_SUBSCRIPTION=true`. One RevenueCat customer binds at most 3 guest identities.
5. Outage behavior: if RevenueCat can't be read, a subscriber confirmed within the last hour keeps working. Otherwise `503 subscription_unverifiable` is returned when a subscription is required (never `402`, which would tell a paying user to pay again), and the free path stays open while the flag is off.
6. `POST /revenuecat/webhook` (Authorization compared in constant time with `REVENUECAT_WEBHOOK_SECRET`) names app users; the Worker re-reads each from RevenueCat and rewrites its cache, so purchases, renewals, cancellations, expirations, billing issues, refunds and transfers take effect immediately. On a read failure after EXPIRATION, CANCELLATION, BILLING_ISSUE, REFUND or SUBSCRIPTION_PAUSED the cached grant is dropped.
7. The token format is unchanged, so conversation history and the guest namespace are preserved across the free to paid transition.
8. `GET /v1/subscribers/{id}` creates the subscriber if RevenueCat has never seen it. The app's SDK normally has, so this adds nothing; caches bound the call volume.

Rust surfaces a Worker `402` as the generic "Hosted guest connection failed (402)". That is acceptable because the client gate shows the paywall first. A typed `SubscriptionRequired` error in `HostedAgentError` would need a UniFFI regeneration, so it is a follow-up.

## Restore, renewal, grace, refund

- Restore: `Purchases.restorePurchases()` then re-read entitlements. In the paywall and Settings > Plan.
- Renewal: `customerInfoStream` refreshes the client; the Worker sees it through RevenueCat (cache or webhook).
- Billing grace: honoured on both sides via RevenueCat's grace-period expiry.
- Refund/revocation: RevenueCat removes the entitlement; the client updates from `customerInfoStream`; the Worker revokes within one cache window, or immediately through the webhook.
- Offline: Plus works offline from RevenueCat's on-device cache; Hosted needs the network anyway.

## Free-user transition

- Server flag `REQUIRE_SUBSCRIPTION` defaults to `false`: nothing changes for existing users until the owner flips it. Order of rollout: ship the app with enforcement, wait for adoption, then flip the flag. While it is `false`, a subscriber simply gets the larger daily budget.
- The client gate ships with the build, so existing Hosted users on the new build see the paywall at their next Hosted send even before the Worker flag flips. This is a product decision.
- Existing conversations and courses are never deleted or locked: gating only blocks new turns. Reading courses stays free.
- New learners are not defaulted into a gated agent (`preferredSetupAgentID` skips gated ones), and are not paywalled at setup either.

## Privacy

RevenueCat is a third-party SDK and service provider. It receives the pseudonymous app user ID, purchase and subscription status, app version, device model/OS, and IP address as network metadata. It does not receive a name, email or Apple ID, and the app does not send IDFA or IDFV. Purpose: subscription management only, not advertising or tracking. `privacy.html`, `PrivacyInfo.xcprivacy` and the App Store privacy labels disclose it; see `docs/releases/app-review-notes.md` for the exact label answers.

## Tests

- Worker (`services/hosted-agent/test/revenuecat.test.ts`, fetch mocked, the real API is never called): ID derivation vector, entitlement states (active, expired, grace, null expiry, refunded, plus-only, sandbox on/off), cache TTLs and the 15 minute cap, outage handling, per-customer budget and bind limit, REQUIRE_SUBSCRIPTION modes, and the webhook (auth, body validation, purchase refresh, terminal-event revocation, unknown users).
- iOS: plan rules, the policy, `SubscriptionStore` against a fake backend, the store's gate including the first-run exemption, ID derivation vector and non-creating identity lookup, configuration parsing (empty, unexpanded, secret keys), the unavailable-purchases path, the StoreKitTest integration test (DEBUG backend against the local `.storekit`), and XCUITests that drive the real paywall with the fixture store, including the purchases-unavailable state.

## Follow-ups (not done)

- A typed `SubscriptionRequired` error from the Rust Hosted client (UniFFI change).
- A yearly plan (add a package and entitlement mapping).
- RevenueCat Paywalls / Customer Center are deliberately not used; the paywall stays our own SwiftUI so the copy and gating stay under our control.
