# Learnfold Hosted Agent

Cloudflare Worker + Durable Object runtime for Learnfold course conversations. It uses Cloudflare Think for server-authoritative transcripts, stream recovery, tool-result continuation, and automatic compaction. The model adapter targets `muse-spark-1.3-contributor` through OpenCode Go's Responses endpoint (`https://opencode.ai/zen/go/v1/responses`). Think replays complete conversation/tool history with `store: false`; provider response IDs are not used as the durable conversation store.

Pi is intentionally not part of this service. Think owns the durable agent loop, while the iOS app executes the allowlisted native course tools and returns their results to the same durable session.

## Local verification

```sh
npm install
npm run types
npm run check
npm test
```

Copy `.dev.vars.example` to `.dev.vars` only for local development. Never commit either secret.

## Deployment

Create two independent secrets:

```sh
npx wrangler secret put OPENCODE_API_KEY
npx wrangler secret put LEARNFOLD_HOSTED_ACCESS_TOKEN
npm run deploy
```

- `OPENCODE_API_KEY` exists only inside the Worker and is sent only to OpenCode.
- `LEARNFOLD_HOSTED_ACCESS_TOKEN` authenticates existing private-beta clients and signs guest session tokens. It must not be the provider key and is never bundled with guest builds.

Configure the iOS build with `LEARNFOLD_HOSTED_AGENT_URL`. No login or access token is required for the beta. The iOS Keychain retains a random 256-bit installation secret, scoped to the service URL. Rust exchanges it at `POST /guest-session?sessionId=<uuid>` using the `Guest` authorization scheme. The returned one-hour bearer token is bound to that guest and conversation. The Worker routes it into a separate guest namespace, preserving history across reconnects without allowing access to another guest's conversation or the legacy shared-token namespace.

Guest access supports only chat WebSocket upgrades. Durable counters allow 120 token exchanges per IP per UTC day, 60 agent turns per guest per day, and 1,000 guest turns globally per day. Think continuations also consume the turn budget. Each guest turn allows at most 12 model steps. Learnfold sends no output-token limit for guest turns, authenticated turns, tool continuations, or compaction; the provider's own model limits still apply. Set `GUEST_BETA_ENABLED` to `"false"` to disable guest bootstrap and further guest turns. Existing shared-token clients remain supported.

`LEARNFOLD_HOSTED_ACCESS_TOKEN` and the corresponding `LearnfoldHostedAccessToken` Info.plist key remain optional runtime overrides for existing private tests. An explicitly empty environment override clears the bundled value. Never put a real shared token in a shipped build. Guest identity is device-local; account-based sync and guest-to-account migration are separate features.

## Paid tier (App Store subscriptions)

Hosted is the paid `Learnfold Hosted` subscription (`com.chirag.learnfold.hosted.monthly`). The Worker, not the app, decides who may use it. The app sends the StoreKit 2 signed transaction (JWS) to the existing guest exchange as a JSON body, `POST /guest-session?sessionId=<uuid>` with `Authorization: Guest <secret>` and `{"signedTransaction": "<JWS>"}`. `src/app-store.ts` verifies it offline, with no call to Apple: the `x5c` chain must end in the pinned Apple Root CA - G3 (SHA-256 `63343abf...e9179`) and carry Apple's marker OIDs, each certificate must be signed by the next and valid, the ES256 signature must verify under the leaf, `bundleId` must match, `productId` must be a configured Hosted product, the type must be an auto-renewable subscription, there must be no `revocationDate`, and the subscription must not be expired beyond the grace window. Failures return `402 {"error":"subscription_invalid","reason":...}`.

A verified transaction stores a server-side entitlement for that guest identity (`entitlement:<guest>` in the `GuestUsage` Durable Object) that lasts until `min(expiresDate + grace, now + 24h)`. The app re-presents its current transaction on every token exchange, so renewals extend it and refunds/revocations/lapses stop it within a day. `enforceGuestTurnLimit` consults it on every turn, including continuations, so a still-valid one-hour token cannot outlive the entitlement by more than that bound. The turn budget is per subscription (`turns:sub:<originalTransactionId>`), and one subscription binds at most `MAX_GUESTS_PER_SUBSCRIPTION` guest identities, so a leaked transaction cannot fan out. The existing per-IP exchange limit still applies. The Worker stores only the hashed guest id, the numeric `originalTransactionId`, the expiry and counters.

Plus (`com.chirag.learnfold.plus.monthly`, bring-your-own runtime) is not enforced here: those agents never touch this Worker, so the app gates them locally.

Optional vars (all strings; defaults in parentheses):

- `REQUIRE_SUBSCRIPTION` (`"false"`): when `"true"`, free guests get `402 subscription_required` at exchange and are refused at every turn; only entitled guests proceed. Leave `"false"` until a build that sends transactions is live, otherwise you lock out current beta users. When `"false"` behavior is unchanged and a verified transaction simply raises the daily budget.
- `GUEST_BETA_ENABLED` (`"true"`): now only governs the free (unsubscribed) guest path. Entitled guests keep working when it is `"false"`.
- `APP_BUNDLE_ID` (`com.chirag.learnfold`), `HOSTED_PRODUCT_IDS` (`com.chirag.learnfold.hosted.monthly`, comma separated, add yearly IDs here).
- `ACCEPT_SANDBOX_TRANSACTIONS` (`"true"`): App Review and TestFlight purchases are signed with the `Sandbox` environment. Xcode StoreKit-file transactions never verify. Set `"false"` only if sandbox access should stop.
- `SUBSCRIPTION_GRACE_SECONDS` (`259200`, three days): extra time past `expiresDate` for Apple's billing-retry grace period. The Worker cannot see Apple's grace state without the App Store Server API, so this approximates it.
- `FREE_TURNS_PER_DAY` (`60`), `PAID_TURNS_PER_DAY` (`150`, per subscription), `PAID_GLOBAL_TURNS_PER_DAY` (`5000`; free guests keep their own `1000` global budget so they cannot starve subscribers).
- `MAX_GUESTS_PER_SUBSCRIPTION` (`3`).
- `APPLE_ROOT_CAS_DER`: comma-separated base64 DER roots that replace the pinned Apple root. For test deployments only.

Not implemented: App Store Server Notifications (V2) webhooks and live revocation lookups. Revocation is detected when the client next exchanges a token. That is the main follow-up if refund abuse matters.

## Diagnosing slow replies

Workers Logs are enabled at a sampling rate of 1. Filter for `component = learnfold.hosted`, or capture a live session with `npx wrangler tail --format json`. Cloudflare may deliver invocation logs together after the invocation completes; tail output is not a continuously queryable in-flight status endpoint.

Correlate the opaque Durable Object `sessionID`, chat `requestID`, and per-provider-call `providerCallID`. The structured records include:

- `chat:turn:start`, `turn.prepared`, `chat:turn:finish`: admission, preparation and completion. Continuations are marked separately.
- `provider.request`, `provider.headers`, `provider.first_byte`: outbound request, HTTP status and first response bytes. `elapsedMs` measures from the provider request.
- `provider.first_reasoning`, `provider.first_text`, `provider.first_tool`: first non-empty reasoning, answer text or tool data in the raw provider SSE stream. Only milestone types are recorded, never content. A long gap between reasoning and text identifies hidden model deliberation; a long wait for headers points earlier in the provider path.
- `model.tool-call` and a subsequent continuation: model handoff to native tools and resumed inference. A handoff without continuation warrants checking the phone connection/tool execution.
- `chat:stream:stalled`, `chat:recovery:*`, `chat:request:failed`, and provider transport/stream errors: watchdog, retry and failure events. HTTP status distinguishes rate limiting from other provider failures.
- `provider.usage`: final numeric token usage when supplied by the provider. Providers may send cumulative usage on every token; these updates are aggregated into one record per HTTP stream.

Learner text, reasoning text, tool names/arguments/results, request URLs, credentials and raw error messages are excluded from this telemetry. SSE inspection buffers at most 64 KiB per line and forwards the original bytes with backpressure and cancellation intact. These records apply only to traffic after the telemetry deployment; they cannot reconstruct earlier uninstrumented requests.

Muse uses its provider defaults for all course turns and compaction, with no reasoning-effort override or app-defined output-token cap. Existing conversations replay their complete history through the same Responses adapter. The model switch preserves lesson prompts and tool authorization rules.

### Provider reasoning activity and timeouts

The observer handles Responses reasoning text/summary deltas, answer deltas, function calls, completion/failure and nested usage. It retains legacy Chat Completions observation for regression coverage. `sendReasoning: false` deliberately hides reasoning from the UI; only real nonempty reasoning deltas produce activity markers. A provider that does not emit reasoning events will not produce invented progress.

The raw SSE observer now forwards only an activity signal for nonempty reasoning deltas. `ProviderProgress` merges a transient `data-hosted-provider-progress` chunk into Think's UI stream, at most once per second while real deltas arrive. It never emits periodic keepalives on silence, and sends no reasoning text. The transient chunk is absent from conversation history; late callbacks are isolated to the original stream. The Rust client recognizes this exact marker as response progress without displaying it as answer text.

Think 0.15.1's 120-second watchdog watches the filtered UI stream. The activity bridge prevents it from treating active hidden reasoning as silence. An AI SDK `timeout.stepMs` of 180 seconds bounds each model step even if reasoning continues. SDK timeout abort chunks are normalized into explicit errors because this Think version otherwise completes them without failure. This preserves user cancellation and genuine inactivity failures; it does not make the model generate its first visible answer faster. Existing app builds still have their prior 180-second content inactivity budget; the Rust activity recognition ships with the next app build.

The bridge uses Think's protected `_transformInferenceResult` hook because this pinned version has no public pre-watchdog UI transform. Keep the real Think/WebSocket regression tests when upgrading Think: they verify sustained reasoning, actual silence, user cancellation, bounded model steps, and no private reasoning in wire messages/history.
