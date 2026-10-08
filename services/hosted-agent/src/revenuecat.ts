// RevenueCat is the source of truth for Hosted subscriptions. The app never
// sends proof of purchase to this Worker. Instead the Worker derives the
// subscriber's RevenueCat app user ID from the guest secret it already receives
// at token exchange, then asks RevenueCat (server to server, with a secret
// key) whether that user holds the `hosted` entitlement.
//
// Why this cannot be claimed by another install: the derivation needs the
// 256-bit guest secret, which is also what authenticates the token exchange.
// Nobody can ask the Worker to look up an ID they do not hold the secret for.

const DEFAULT_API_BASE = "https://api.revenuecat.com/v1"
const DEFAULT_ENTITLEMENT = "hosted"
const REQUEST_TIMEOUT_MS = 5000

/**
 * Domain separation: RevenueCat (a third party) receives this derived ID, never
 * the guest secret and never the hash the Worker uses as the conversation
 * namespace (`guest-<sha256(secret)>`). The iOS app computes the same value in
 * `HostedGuestIdentity.revenueCatAppUserID(secret:)`. Both sides are pinned by a
 * shared test vector; change neither without the other.
 */
export const APP_USER_ID_DOMAIN = "learnfold.revenuecat.app-user.v1:"
export const APP_USER_ID_PATTERN = /^lf1_[0-9a-f]{64}$/

export type RevenueCatEnv = {
  /** Worker secret. A RevenueCat v1 secret API key (`sk_...`). */
  REVENUECAT_SECRET_API_KEY?: string
  /** Worker secret. Compared constant-time against the webhook Authorization header. */
  REVENUECAT_WEBHOOK_SECRET?: string
  REVENUECAT_HOSTED_ENTITLEMENT?: string
  REVENUECAT_API_BASE_URL?: string
  ACCEPT_SANDBOX_TRANSACTIONS?: string
}

export type SubscriberLookup =
  | {
    status: "active"
    originalAppUserId: string
    /** Entitlement expiry including any billing grace period; `null` means it does not expire. */
    expiresAt: number | null
    sandbox: boolean
  }
  | { status: "inactive"; reason: "no_entitlement" | "expired" | "refunded" | "sandbox_not_accepted" }
  | { status: "error"; reason: "not_configured" | "unreachable" | "rejected" | "malformed" }

export async function revenueCatAppUserId(guestSecret: string): Promise<string> {
  const bytes = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(APP_USER_ID_DOMAIN + guestSecret))
  return `lf1_${Array.from(new Uint8Array(bytes), (byte) => byte.toString(16).padStart(2, "0")).join("")}`
}

export function revenueCatConfigured(env: object): boolean {
  return Boolean((env as RevenueCatEnv).REVENUECAT_SECRET_API_KEY?.trim())
}

export function acceptsSandbox(env: object): boolean {
  return (env as RevenueCatEnv).ACCEPT_SANDBOX_TRANSACTIONS !== "false"
}

type RevenueCatEntitlement = {
  expires_date?: string | null
  grace_period_expires_date?: string | null
  product_identifier?: string
}

type RevenueCatSubscription = {
  is_sandbox?: boolean
  refunded_at?: string | null
  store?: string
}

type SubscriberResponse = {
  subscriber?: {
    original_app_user_id?: string
    entitlements?: Record<string, RevenueCatEntitlement>
    subscriptions?: Record<string, RevenueCatSubscription>
  }
}

function parseDate(value: string | null | undefined): number | null {
  if (!value) return null
  const time = Date.parse(value)
  return Number.isNaN(time) ? null : time
}

/**
 * Asks RevenueCat for one subscriber and decides whether `hosted` is active.
 * GET /v1/subscribers/{id} creates the subscriber if RevenueCat has never seen
 * the ID. That is harmless here: the app's SDK registers the same ID at launch.
 */
export async function lookupHostedSubscriber(appUserId: string, env: object, now = Date.now()): Promise<SubscriberLookup> {
  const config = env as RevenueCatEnv
  const key = config.REVENUECAT_SECRET_API_KEY?.trim()
  if (!key) return { status: "error", reason: "not_configured" }
  if (!APP_USER_ID_PATTERN.test(appUserId)) return { status: "inactive", reason: "no_entitlement" }

  const base = (config.REVENUECAT_API_BASE_URL?.trim() || DEFAULT_API_BASE).replace(/\/+$/, "")
  let response: Response
  try {
    response = await fetch(`${base}/subscribers/${encodeURIComponent(appUserId)}`, {
      headers: { authorization: `Bearer ${key}`, accept: "application/json", "x-platform": "ios" },
      signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS),
    })
  } catch {
    return { status: "error", reason: "unreachable" }
  }
  if (response.status === 404) return { status: "inactive", reason: "no_entitlement" }
  // A rejected key (401/403) or a rate limit (429) says nothing about the user.
  if (response.status === 401 || response.status === 403 || response.status === 429) return { status: "error", reason: "rejected" }
  if (!response.ok) return { status: "error", reason: "unreachable" }

  let body: SubscriberResponse
  try {
    body = await response.json<SubscriberResponse>()
  } catch {
    return { status: "error", reason: "malformed" }
  }
  const subscriber = body.subscriber
  if (!subscriber || typeof subscriber !== "object") return { status: "error", reason: "malformed" }

  const entitlement = subscriber.entitlements?.[config.REVENUECAT_HOSTED_ENTITLEMENT?.trim() || DEFAULT_ENTITLEMENT]
  if (!entitlement) return { status: "inactive", reason: "no_entitlement" }

  // `expires_date: null` is a non-expiring grant (for example a promotional
  // entitlement the owner gave an App Review account). Otherwise the
  // entitlement is active until its expiry, or until the end of the billing
  // grace period, whichever is later. RevenueCat keeps a subscription in grace
  // listed as an entitlement and reports the grace deadline separately.
  const expires = parseDate(entitlement.expires_date)
  const grace = parseDate(entitlement.grace_period_expires_date)
  const neverExpires = entitlement.expires_date === null || entitlement.expires_date === undefined
  const expiresAt = neverExpires ? null : Math.max(expires ?? 0, grace ?? 0)
  if (expiresAt !== null && expiresAt <= now) return { status: "inactive", reason: "expired" }

  const subscription = entitlement.product_identifier ? subscriber.subscriptions?.[entitlement.product_identifier] : undefined
  if (subscription?.refunded_at) return { status: "inactive", reason: "refunded" }
  const sandbox = subscription?.is_sandbox === true
  if (sandbox && !acceptsSandbox(env)) return { status: "inactive", reason: "sandbox_not_accepted" }

  return {
    status: "active",
    originalAppUserId: subscriber.original_app_user_id || appUserId,
    expiresAt,
    sandbox,
  }
}

async function digest(value: string): Promise<ArrayBuffer> {
  return crypto.subtle.digest("SHA-256", new TextEncoder().encode(value))
}

/**
 * RevenueCat sends the exact string configured as the webhook's Authorization
 * header value. Accept that string verbatim or as a Bearer token. The compare
 * is constant-time over fixed-length digests.
 */
export async function webhookAuthorized(request: Request, env: object): Promise<boolean> {
  const secret = (env as RevenueCatEnv).REVENUECAT_WEBHOOK_SECRET?.trim()
  const header = request.headers.get("authorization")?.trim()
  if (!secret || !header) return false
  const expected = await digest(secret)
  const direct = crypto.subtle.timingSafeEqual(await digest(header), expected)
  const bearer = header.startsWith("Bearer ")
    && crypto.subtle.timingSafeEqual(await digest(header.slice(7).trim()), expected)
  return direct || bearer
}

export type WebhookEvent = { type: string; appUserIds: string[] }

/** Event types after which a failed refresh must not leave a stale grant behind. */
export const TERMINAL_EVENT_TYPES = new Set(["EXPIRATION", "CANCELLATION", "BILLING_ISSUE", "REFUND", "SUBSCRIPTION_PAUSED"])

export function parseWebhook(body: unknown): WebhookEvent | null {
  if (!body || typeof body !== "object") return null
  const event = (body as { event?: unknown }).event
  if (!event || typeof event !== "object") return null
  const record = event as Record<string, unknown>
  if (typeof record.type !== "string") return null
  const ids = new Set<string>()
  const add = (value: unknown) => {
    if (typeof value === "string" && APP_USER_ID_PATTERN.test(value)) ids.add(value)
  }
  add(record.app_user_id)
  add(record.original_app_user_id)
  for (const list of [record.aliases, record.transferred_from, record.transferred_to]) {
    if (Array.isArray(list)) list.forEach(add)
  }
  return { type: record.type, appUserIds: [...ids] }
}
