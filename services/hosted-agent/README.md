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

## Paid tier (RevenueCat subscriptions)

Hosted is the paid `Learnfold Hosted` subscription (`com.chirag.learnfold.hosted.monthly`), sold through the App Store and managed by RevenueCat. The Worker, not the app, decides who may use it, and the app sends no proof of purchase. At `POST /guest-session` the Worker already receives the installation's guest secret (`Authorization: Guest <secret>`). It derives the subscriber's RevenueCat app user ID from that secret and asks RevenueCat server to server:

```
appUserId = "lf1_" + hex(SHA-256("learnfold.revenuecat.app-user.v1:" + guestSecret))
GET https://api.revenuecat.com/v1/subscribers/{appUserId}     Authorization: Bearer <REVENUECAT_SECRET_API_KEY>
```

The iOS app computes the same ID (`HostedGuestIdentity.revenueCatAppUserID(secret:)`) and passes it to the RevenueCat SDK, so a purchase made in the app lands on the ID the Worker looks up. A shared test vector pins both sides. The ID is one-way and domain separated: RevenueCat never sees the guest secret or the `guest-<sha256(secret)>` conversation namespace. Because the lookup key comes from the secret that authenticates the request, one install cannot claim another's entitlement. Nothing about the subscriber's name or Apple ID reaches the Worker.

`src/revenuecat.ts` treats the `hosted` entitlement as active when `expires_date` is in the future, or its `grace_period_expires_date` is (billing retry), or `expires_date` is `null` (a non-expiring grant, for example a promotional entitlement for an App Review account). Refunded subscriptions are rejected. Sandbox purchases, which App Review and TestFlight make, are accepted unless `ACCEPT_SANDBOX_TRANSACTIONS` is `"false"`. Plus-only customers have no `hosted` entitlement and are treated as free here.

The answer is cached per guest in the `GuestUsage` Durable Object (`entitlement:<guest>`): at most 15 minutes for a subscriber (`REVENUECAT_CACHE_SECONDS` can only lower that), 60 seconds for a guest with no entitlement so a new purchase is noticed quickly. `enforceGuestTurnLimit` runs on every turn and continuation and re-checks a stale subscriber entry with RevenueCat, so a long-lived connection cannot outlive a lapsed subscription by more than the cache window. If RevenueCat is unreachable, a subscriber confirmed within the last hour keeps working; otherwise the Worker answers `503 subscription_unverifiable` when a subscription is required (never `402`, which would wrongly tell a subscriber to pay again). The turn budget is per RevenueCat customer (`turns:sub:<original_app_user_id>`), and one customer binds at most `MAX_GUESTS_PER_SUBSCRIPTION` guest identities. The Worker stores only hashed IDs, the RevenueCat `original_app_user_id`, the expiry and counters.

`POST /revenuecat/webhook` keeps this fresh. Configure it in RevenueCat (Project settings > Integrations > Webhooks) with the `Authorization` header value set to the same string as `REVENUECAT_WEBHOOK_SECRET`; the Worker accepts that string verbatim or as `Bearer <secret>` and compares it in constant time. The event body is not trusted for entitlement state. It only names app users, and the Worker re-reads each from RevenueCat (so purchases take effect at once, and expirations, cancellations, billing issues and refunds revoke at once). If RevenueCat cannot be read right after one of those events, the cached grant is dropped. Always answers `200` once authenticated so RevenueCat does not retry.

Plus (`com.chirag.learnfold.plus.monthly`, bring-your-own runtime) is not enforced here: those agents never touch this Worker, so the app gates them locally from RevenueCat's `plus` entitlement.

Secrets (`npx wrangler secret put <NAME>`):

- `REVENUECAT_SECRET_API_KEY`: RevenueCat v1 **secret** API key (`sk_...`, Project settings > API keys). Without it the Worker never calls RevenueCat and every guest is on the free path. The public SDK key (`appl_...`) belongs in the iOS build, never here.
- `REVENUECAT_WEBHOOK_SECRET`: shared secret for `POST /revenuecat/webhook`. Without it the endpoint rejects everything.

Optional vars (all strings; defaults in parentheses):

- `REQUIRE_SUBSCRIPTION` (`"false"`): when `"true"`, guests without the `hosted` entitlement get `402 subscription_required` at exchange and are refused at every turn; only subscribers proceed. Leave `"false"` until a build with purchases is live, otherwise you lock out current beta users. When `"false"` behavior is unchanged and a subscriber simply gets the larger daily budget.
- `GUEST_BETA_ENABLED` (`"true"`): only governs the free (unsubscribed) guest path. Subscribers keep working when it is `"false"`.
- `ACCEPT_SANDBOX_TRANSACTIONS` (`"true"`): App Review and TestFlight purchases are Sandbox. Set `"false"` only if sandbox access should stop.
- `REVENUECAT_HOSTED_ENTITLEMENT` (`hosted`): the RevenueCat entitlement identifier that grants Hosted.
- `REVENUECAT_CACHE_SECONDS` (`900`, capped at 900), `REVENUECAT_NEGATIVE_CACHE_SECONDS` (`60`).
- `REVENUECAT_API_BASE_URL` (`https://api.revenuecat.com/v1`): for tests and proxies only.
- `FREE_TURNS_PER_DAY` (`60`), `PAID_TURNS_PER_DAY` (`150`, per customer), `PAID_GLOBAL_TURNS_PER_DAY` (`5000`; free guests keep their own `1000` global budget so they cannot starve subscribers).
- `MAX_GUESTS_PER_SUBSCRIPTION` (`3`).

RevenueCat's REST API is rate limited, and `GET /v1/subscribers/{id}` creates the subscriber if RevenueCat has never seen the ID (the app's SDK normally has, so this adds nothing). The caches above keep the call volume to roughly one request per active guest per cache window.

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
