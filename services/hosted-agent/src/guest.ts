import { DurableObject } from "cloudflare:workers"

import {
  TERMINAL_EVENT_TYPES,
  lookupHostedSubscriber,
  parseWebhook,
  revenueCatAppUserId,
  revenueCatConfigured,
  webhookAuthorized,
} from "./revenuecat"

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/
const HEX_SECRET = /^[0-9a-f]{64}$/
const TOKEN_TTL_SECONDS = 3600
// A RevenueCat answer is trusted for at most this long, whatever the config says.
const MAX_ENTITLEMENT_CACHE_SECONDS = 900
const DEFAULT_NEGATIVE_CACHE_SECONDS = 60
// If RevenueCat is unreachable, a subscriber last confirmed within this window
// keeps working rather than being locked out by someone else's outage.
const STALE_IF_ERROR_MS = 3600 * 1000

// Optional configuration. All are strings because Workers vars are strings.
type SubscriptionEnv = Env & {
  FREE_TURNS_PER_DAY?: string
  PAID_TURNS_PER_DAY?: string
  PAID_GLOBAL_TURNS_PER_DAY?: string
  MAX_GUESTS_PER_SUBSCRIPTION?: string
  REVENUECAT_CACHE_SECONDS?: string
  REVENUECAT_NEGATIVE_CACHE_SECONDS?: string
}

function intVar(value: string | undefined, fallback: number): number {
  const parsed = Number(value)
  return value !== undefined && value.trim() !== "" && Number.isInteger(parsed) && parsed >= 0 ? parsed : fallback
}

export function subscriptionRequired(env: Env): boolean {
  // Generated types narrow the wrangler.jsonc default to the literal "false".
  return (env as { REQUIRE_SUBSCRIPTION?: string }).REQUIRE_SUBSCRIPTION === "true"
}

function cacheMs(env: Env): { positive: number; negative: number } {
  const config = env as SubscriptionEnv
  return {
    positive: Math.min(intVar(config.REVENUECAT_CACHE_SECONDS, MAX_ENTITLEMENT_CACHE_SECONDS), MAX_ENTITLEMENT_CACHE_SECONDS) * 1000,
    negative: intVar(config.REVENUECAT_NEGATIVE_CACHE_SECONDS, DEFAULT_NEGATIVE_CACHE_SECONDS) * 1000,
  }
}

/** What the Worker last learned from RevenueCat about one guest's Hosted entitlement. */
export type CachedEntitlement = {
  appUserId: string
  /** RevenueCat's `original_app_user_id`; the key for the per-subscription budget and bind limit. */
  originalAppUserId: string
  entitled: boolean
  /** Entitlement expiry including grace; `null` when it never expires. */
  expiresAt: number | null
  checkedAt: number
}

const ENTITLEMENT_TABLE = "CREATE TABLE IF NOT EXISTS hosted_entitlement (id INTEGER PRIMARY KEY, app_user_id TEXT, original TEXT, entitled INTEGER, expires_at INTEGER, checked_at INTEGER)"

// One durable counter per guest, IP, or global budget. Count turns inside Think,
// not just socket upgrades, so a persistent connection cannot bypass the cap.
export class GuestUsage extends DurableObject<Env> {
  consume(limit: number): boolean {
    const sql = this.ctx.storage.sql
    return this.ctx.storage.transactionSync(() => {
      sql.exec("CREATE TABLE IF NOT EXISTS usage (id INTEGER PRIMARY KEY, day TEXT, count INTEGER)")
      const day = new Date().toISOString().slice(0, 10)
      const row = sql.exec<{ day: string; count: number }>("SELECT day, count FROM usage WHERE id = 1").toArray()[0]
      const used = row?.day === day ? row.count : 0
      if (used >= limit) return false
      sql.exec("INSERT OR REPLACE INTO usage (id, day, count) VALUES (1, ?, ?)", day, used + 1)
      return true
    })
  }

  // `subscription:<originalAppUserId>`: bind guest identities to one RevenueCat
  // customer. An entitlement that RevenueCat aliases across several guest
  // identities cannot fan out to unlimited guests.
  bindGuest(subject: string, maxGuests: number): boolean {
    const sql = this.ctx.storage.sql
    return this.ctx.storage.transactionSync(() => {
      sql.exec("CREATE TABLE IF NOT EXISTS guests (subject TEXT PRIMARY KEY)")
      const known = sql.exec("SELECT 1 FROM guests WHERE subject = ?", subject).toArray().length > 0
      if (known) return true
      const count = sql.exec<{ n: number }>("SELECT COUNT(*) AS n FROM guests").one().n
      if (count >= maxGuests) return false
      sql.exec("INSERT INTO guests (subject) VALUES (?)", subject)
      return true
    })
  }

  // `entitlement:<guest>`: the last RevenueCat answer for this guest. Readers
  // decide freshness (see `resolveEntitlement`); this only stores and returns it.
  saveEntitlement(entry: CachedEntitlement): void {
    const sql = this.ctx.storage.sql
    sql.exec(ENTITLEMENT_TABLE)
    sql.exec(
      "INSERT OR REPLACE INTO hosted_entitlement (id, app_user_id, original, entitled, expires_at, checked_at) VALUES (1, ?, ?, ?, ?, ?)",
      entry.appUserId, entry.originalAppUserId, entry.entitled ? 1 : 0, entry.expiresAt, entry.checkedAt,
    )
  }

  cachedEntitlement(): CachedEntitlement | null {
    const sql = this.ctx.storage.sql
    sql.exec(ENTITLEMENT_TABLE)
    const row = sql.exec<{ app_user_id: string; original: string; entitled: number; expires_at: number | null; checked_at: number }>(
      "SELECT app_user_id, original, entitled, expires_at, checked_at FROM hosted_entitlement WHERE id = 1",
    ).toArray()[0]
    return row
      ? { appUserId: row.app_user_id, originalAppUserId: row.original, entitled: row.entitled === 1, expiresAt: row.expires_at, checkedAt: row.checked_at }
      : null
  }

  clearEntitlement(): void {
    const sql = this.ctx.storage.sql
    sql.exec(ENTITLEMENT_TABLE)
    sql.exec("DELETE FROM hosted_entitlement")
  }

  // `rc-user:<appUserId>`: maps a RevenueCat app user back to the guest it was
  // derived from, so a webhook can refresh the right entitlement.
  setSubject(subject: string): void {
    const sql = this.ctx.storage.sql
    sql.exec("CREATE TABLE IF NOT EXISTS subject (id INTEGER PRIMARY KEY, value TEXT)")
    sql.exec("INSERT OR REPLACE INTO subject (id, value) VALUES (1, ?)", subject)
  }

  subject(): string | null {
    const sql = this.ctx.storage.sql
    sql.exec("CREATE TABLE IF NOT EXISTS subject (id INTEGER PRIMARY KEY, value TEXT)")
    return sql.exec<{ value: string }>("SELECT value FROM subject WHERE id = 1").toArray()[0]?.value ?? null
  }
}

export async function hashIdentity(secret: string): Promise<string> {
  const bytes = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(secret))
  return Array.from(new Uint8Array(bytes), (byte) => byte.toString(16).padStart(2, "0")).join("")
}

async function signingKey(secret: string): Promise<CryptoKey> {
  return crypto.subtle.importKey("raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign", "verify"])
}

export async function mintGuestToken(secret: string, subject: string, session: string, now = Date.now()): Promise<string> {
  const payload = `guest-v1.${subject}.${session}.${Math.floor(now / 1000) + TOKEN_TTL_SECONDS}`
  const signature = await crypto.subtle.sign("HMAC", await signingKey(secret), new TextEncoder().encode(payload))
  return `${payload}.${btoa(String.fromCharCode(...new Uint8Array(signature))).replaceAll("+", "-").replaceAll("/", "_").replaceAll("=", "")}`
}

export async function verifyGuestToken(token: string, secret: string, session: string, now = Date.now()): Promise<string | null> {
  const parts = token.split(".")
  if (!secret || parts.length !== 5 || parts[0] !== "guest-v1" || !HEX_SECRET.test(parts[1])
    || parts[2] !== session || !UUID.test(session) || !/^\d+$/.test(parts[3])
    || Number(parts[3]) <= Math.floor(now / 1000) || !/^[A-Za-z0-9_-]{43}$/.test(parts[4])) return null
  try {
    const signature = Uint8Array.from(atob(parts[4].replaceAll("-", "+").replaceAll("_", "/") + "="), (c) => c.charCodeAt(0))
    const valid = await crypto.subtle.verify("HMAC", await signingKey(secret), signature, new TextEncoder().encode(parts.slice(0, 4).join(".")))
    return valid ? parts[1] : null
  } catch {
    return null
  }
}

function isFresh(entry: CachedEntitlement, env: Env, now: number): boolean {
  const ttl = cacheMs(env)
  if (entry.checkedAt > now) return false
  if (!entry.entitled) return now - entry.checkedAt < ttl.negative
  if (entry.expiresAt !== null && entry.expiresAt <= now) return false
  return now - entry.checkedAt < ttl.positive
}

function isActive(entry: CachedEntitlement, now: number): boolean {
  return entry.entitled && (entry.expiresAt === null || entry.expiresAt > now)
}

export type EntitlementResolution =
  | { kind: "entitled"; entitlement: CachedEntitlement }
  | { kind: "free" }
  /** RevenueCat could not be asked or did not answer, and nothing recent is cached. */
  | { kind: "unavailable" }

/**
 * Whether this guest currently holds the Hosted entitlement. Answers from the
 * short-lived cache in the guest's `GuestUsage` object when it is fresh, and
 * otherwise asks RevenueCat. The result is authoritative for budgets and for
 * REQUIRE_SUBSCRIPTION; the app's own view of its plan is only a UX hint.
 */
export async function resolveEntitlement(
  env: Env,
  subject: string,
  appUserId: string,
  now = Date.now(),
): Promise<EntitlementResolution> {
  const store = env.GuestUsage.getByName(`entitlement:${subject}`)
  const cached = await store.cachedEntitlement()
  if (cached && cached.appUserId === appUserId && isFresh(cached, env, now)) {
    return isActive(cached, now) ? { kind: "entitled", entitlement: cached } : { kind: "free" }
  }
  if (!revenueCatConfigured(env)) return { kind: "free" }

  const lookup = await lookupHostedSubscriber(appUserId, env, now)
  if (lookup.status === "error") {
    // Keep a recently confirmed subscriber working through a RevenueCat outage.
    if (cached && cached.appUserId === appUserId && isActive(cached, now) && now - cached.checkedAt < STALE_IF_ERROR_MS) {
      return { kind: "entitled", entitlement: cached }
    }
    return { kind: "unavailable" }
  }

  const entry: CachedEntitlement = lookup.status === "active"
    ? { appUserId, originalAppUserId: lookup.originalAppUserId, entitled: true, expiresAt: lookup.expiresAt, checkedAt: now }
    : { appUserId, originalAppUserId: appUserId, entitled: false, expiresAt: null, checkedAt: now }
  await store.saveEntitlement(entry)
  await env.GuestUsage.getByName(`rc-user:${appUserId}`).setSubject(subject)
  return entry.entitled ? { kind: "entitled", entitlement: entry } : { kind: "free" }
}

function unavailableResponse(): Response {
  return Response.json(
    { error: "subscription_unverifiable" },
    { status: 503, headers: { "cache-control": "no-store" } },
  )
}

export async function guestSession(request: Request, env: Env, signingSecret: string): Promise<Response> {
  if (!signingSecret) {
    return Response.json({ error: "Hosted guest access is temporarily unavailable." }, { status: 503 })
  }
  const secret = request.headers.get("authorization")?.match(/^Guest ([0-9a-f]{64})$/)?.[1]
  const session = new URL(request.url).searchParams.get("sessionId") ?? ""
  if (!secret || !UUID.test(session)) return Response.json({ error: "invalid_guest_session" }, { status: 400 })
  const ip = request.headers.get("cf-connecting-ip") ?? "local"
  const ipID = await hashIdentity(ip)
  const subject = await hashIdentity(secret)

  // The subscriber is identified by a value derived from the secret this very
  // request authenticates with, so a caller can only ever look up their own.
  const resolution = await resolveEntitlement(env, subject, await revenueCatAppUserId(secret))
  if (resolution.kind === "entitled") {
    const config = env as SubscriptionEnv
    if (!await env.GuestUsage.getByName(`subscription:${resolution.entitlement.originalAppUserId}`)
      .bindGuest(subject, intVar(config.MAX_GUESTS_PER_SUBSCRIPTION, 3))) {
      return Response.json({ error: "subscription_in_use", reason: "too_many_devices" }, { status: 409, headers: { "cache-control": "no-store" } })
    }
  } else if (subscriptionRequired(env)) {
    return resolution.kind === "unavailable"
      ? unavailableResponse()
      : Response.json({ error: "subscription_required" }, { status: 402, headers: { "cache-control": "no-store" } })
  } else if (env.GUEST_BETA_ENABLED !== "true") {
    return Response.json({ error: "Hosted guest access is temporarily unavailable." }, { status: 503 })
  }
  if (!await env.GuestUsage.getByName(`bootstrap:${ipID}`).consume(120)) {
    return Response.json({ error: "Hosted is busy right now. Please try again tomorrow." }, { status: 429 })
  }
  return Response.json({ accessToken: await mintGuestToken(signingSecret, subject, session) }, {
    headers: { "cache-control": "no-store" },
  })
}

export async function authorizeGuestRoute(request: Request, signingSecret: string): Promise<Request | null> {
  const url = new URL(request.url)
  const session = url.pathname.match(/^\/agents\/hosted-course-agent\/([0-9a-f-]+)$/)?.[1]
  // Guests only use the chat protocol. Do not expose arbitrary Agent HTTP/RPC routes.
  if (!session || request.method !== "GET" || request.headers.get("upgrade")?.toLowerCase() !== "websocket") return null
  const token = request.headers.get("authorization")?.replace(/^Bearer /, "") ?? ""
  const subject = await verifyGuestToken(token, signingSecret, session)
  if (!subject) return null
  url.pathname = `/agents/hosted-course-agent/guest-${subject}-${session}`
  return new Request(url, request)
}

export async function enforceGuestTurnLimit(name: string, env: Env): Promise<void> {
  const subject = name.match(/^guest-([0-9a-f]{64})-/)?.[1]
  if (!subject) return
  const config = env as SubscriptionEnv
  // Authoritative entitlement decision. Only guestSession() creates a cache
  // entry (a guest that never exchanged a token has none and is free). A stale
  // subscriber entry is re-checked with RevenueCat, so a connection that
  // outlives the cache still gets the right budget and a lapsed subscription
  // stops within one cache window.
  const known = await env.GuestUsage.getByName(`entitlement:${subject}`).cachedEntitlement()
  const resolution = known && (known.entitled || subscriptionRequired(env))
    ? await resolveEntitlement(env, subject, known.appUserId)
    : { kind: "free" } as const
  if (resolution.kind === "entitled") {
    // Budget is per subscription, so several bound guests cannot multiply it.
    if (!await env.GuestUsage.getByName(`turns:sub:${resolution.entitlement.originalAppUserId}`).consume(intVar(config.PAID_TURNS_PER_DAY, 150))) {
      throw new Error("You've reached today's Hosted limit for your subscription. Your course is saved. Please continue tomorrow.")
    }
    if (!await env.GuestUsage.getByName("turns:global:paid").consume(intVar(config.PAID_GLOBAL_TURNS_PER_DAY, 5000))) {
      throw new Error("Hosted has reached today's capacity. Your course is saved. Please continue tomorrow.")
    }
    return
  }
  if (resolution.kind === "unavailable") {
    throw new Error("Hosted couldn't confirm your subscription right now. Your course is saved. Please try again in a few minutes.")
  }
  if (subscriptionRequired(env)) {
    throw new Error("Hosted needs an active Learnfold Hosted subscription. Open Settings > Plan to subscribe, or choose another agent.")
  }
  if (env.GUEST_BETA_ENABLED !== "true") throw new Error("Hosted guest access is temporarily unavailable.")
  if (!await env.GuestUsage.getByName(`turns:${subject}`).consume(intVar(config.FREE_TURNS_PER_DAY, 60))) {
    throw new Error("You've reached today's Hosted usage limit. Your course is saved. Please continue tomorrow.")
  }
  if (!await env.GuestUsage.getByName("turns:global").consume(1000)) {
    throw new Error("Hosted has reached today's capacity. Your course is saved. Please continue tomorrow.")
  }
}

/**
 * `POST /revenuecat/webhook`. RevenueCat calls this on purchases, renewals,
 * cancellations, expirations, billing issues, refunds and transfers. The body
 * is never trusted for entitlement state: the event only names app users whose
 * entitlement the Worker then re-reads from RevenueCat.
 */
export async function revenueCatWebhook(request: Request, env: Env): Promise<Response> {
  if (!await webhookAuthorized(request, env)) {
    return Response.json({ error: "unauthorized" }, { status: 401, headers: { "cache-control": "no-store" } })
  }
  let body: unknown
  try {
    body = await request.json()
  } catch {
    return Response.json({ error: "invalid_body" }, { status: 400, headers: { "cache-control": "no-store" } })
  }
  const event = parseWebhook(body)
  if (!event) return Response.json({ error: "invalid_body" }, { status: 400, headers: { "cache-control": "no-store" } })

  let refreshed = 0
  for (const appUserId of event.appUserIds) {
    const subject = await env.GuestUsage.getByName(`rc-user:${appUserId}`).subject()
    if (!subject) continue // This user never opened a Hosted session; nothing is cached.
    const store = env.GuestUsage.getByName(`entitlement:${subject}`)
    const lookup = revenueCatConfigured(env) ? await lookupHostedSubscriber(appUserId, env) : { status: "error" } as const
    if (lookup.status === "error") {
      // Could not read the truth. After an event that ends access, do not leave
      // the old grant in place; after anything else the short cache covers it.
      if (TERMINAL_EVENT_TYPES.has(event.type)) await store.clearEntitlement()
    } else if (lookup.status === "active") {
      await store.saveEntitlement({
        appUserId,
        originalAppUserId: lookup.originalAppUserId,
        entitled: true,
        expiresAt: lookup.expiresAt,
        checkedAt: Date.now(),
      })
    } else {
      await store.saveEntitlement({ appUserId, originalAppUserId: appUserId, entitled: false, expiresAt: null, checkedAt: Date.now() })
    }
    refreshed++
  }
  return Response.json({ ok: true, refreshed }, { headers: { "cache-control": "no-store" } })
}
