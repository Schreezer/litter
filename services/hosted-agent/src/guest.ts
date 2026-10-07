import { DurableObject } from "cloudflare:workers"

import { SubscriptionError, verifySignedTransaction } from "./app-store"
import type { VerifiedTransaction } from "./app-store"

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/
const HEX_SECRET = /^[0-9a-f]{64}$/
const TOKEN_TTL_SECONDS = 3600
// A verified transaction buys at most this long of server-side entitlement; the
// client re-presents its current transaction on every guest token exchange.
const ENTITLEMENT_MAX_SECONDS = 24 * 3600
const DEFAULT_GRACE_SECONDS = 3 * 24 * 3600
const DEFAULT_BUNDLE_ID = "com.chirag.learnfold"
const DEFAULT_HOSTED_PRODUCT = "com.chirag.learnfold.hosted.monthly"

// Optional configuration. All are strings because Workers vars are strings.
type SubscriptionEnv = Env & {
  APP_BUNDLE_ID?: string
  HOSTED_PRODUCT_IDS?: string
  ACCEPT_SANDBOX_TRANSACTIONS?: string
  SUBSCRIPTION_GRACE_SECONDS?: string
  FREE_TURNS_PER_DAY?: string
  PAID_TURNS_PER_DAY?: string
  PAID_GLOBAL_TURNS_PER_DAY?: string
  MAX_GUESTS_PER_SUBSCRIPTION?: string
  APPLE_ROOT_CAS_DER?: string
}

function intVar(value: string | undefined, fallback: number): number {
  const parsed = Number(value)
  return value !== undefined && value.trim() !== "" && Number.isInteger(parsed) && parsed >= 0 ? parsed : fallback
}

export function subscriptionRequired(env: Env): boolean {
  // Generated types narrow the wrangler.jsonc default to the literal "false".
  return (env as { REQUIRE_SUBSCRIPTION?: string }).REQUIRE_SUBSCRIPTION === "true"
}

/** Verifies a StoreKit 2 signed transaction against this deployment's config. */
export function verifyHostedTransaction(jws: string, env: Env, now = Date.now()): Promise<VerifiedTransaction> {
  const config = env as SubscriptionEnv
  const productIDs = (config.HOSTED_PRODUCT_IDS ?? DEFAULT_HOSTED_PRODUCT).split(",").map((id) => id.trim()).filter(Boolean)
  return verifySignedTransaction(jws, {
    bundleId: config.APP_BUNDLE_ID || DEFAULT_BUNDLE_ID,
    products: Object.fromEntries(productIDs.map((id) => [id, "hosted"])),
    trustedRootsDER: config.APPLE_ROOT_CAS_DER ? config.APPLE_ROOT_CAS_DER.split(",").map((item) => item.trim()) : undefined,
    acceptSandbox: config.ACCEPT_SANDBOX_TRANSACTIONS !== "false",
    graceMs: intVar(config.SUBSCRIPTION_GRACE_SECONDS, DEFAULT_GRACE_SECONDS) * 1000,
    now,
  })
}

export type Entitlement = { originalTransactionId: string; validUntil: number }

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

  // `subscription:<originalTransactionId>`: bind a guest identity to one
  // subscription. A leaked/shared transaction cannot fan out to unlimited guests.
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

  // `entitlement:<guest>`: what a verified subscription currently allows.
  setEntitlement(originalTransactionId: string, validUntil: number): void {
    const sql = this.ctx.storage.sql
    sql.exec("CREATE TABLE IF NOT EXISTS entitlement (id INTEGER PRIMARY KEY, original TEXT, valid_until INTEGER)")
    sql.exec("INSERT OR REPLACE INTO entitlement (id, original, valid_until) VALUES (1, ?, ?)", originalTransactionId, validUntil)
  }

  entitlement(now: number): Entitlement | null {
    const sql = this.ctx.storage.sql
    sql.exec("CREATE TABLE IF NOT EXISTS entitlement (id INTEGER PRIMARY KEY, original TEXT, valid_until INTEGER)")
    const row = sql.exec<{ original: string; valid_until: number }>("SELECT original, valid_until FROM entitlement WHERE id = 1").toArray()[0]
    return row && row.valid_until > now ? { originalTransactionId: row.original, validUntil: row.valid_until } : null
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

  // Optional proof of purchase: {"signedTransaction": "<StoreKit 2 JWS>"}.
  let signedTransaction: string | undefined
  if (request.headers.get("content-type")?.includes("application/json")) {
    try {
      const value = (await request.json<{ signedTransaction?: unknown }>()).signedTransaction
      if (typeof value === "string" && value) signedTransaction = value
    } catch { /* A body that is not JSON carries no transaction. */ }
  }
  if (signedTransaction) {
    let verified: VerifiedTransaction
    try {
      verified = await verifyHostedTransaction(signedTransaction, env)
    } catch (error) {
      const reason = error instanceof SubscriptionError ? error.reason : "malformed"
      return Response.json({ error: "subscription_invalid", reason }, { status: 402, headers: { "cache-control": "no-store" } })
    }
    const config = env as SubscriptionEnv
    if (!await env.GuestUsage.getByName(`subscription:${verified.originalTransactionId}`)
      .bindGuest(subject, intVar(config.MAX_GUESTS_PER_SUBSCRIPTION, 3))) {
      return Response.json({ error: "subscription_in_use", reason: "too_many_devices" }, { status: 409, headers: { "cache-control": "no-store" } })
    }
    const now = Date.now()
    const graceMs = intVar(config.SUBSCRIPTION_GRACE_SECONDS, DEFAULT_GRACE_SECONDS) * 1000
    const validUntil = Math.min(verified.expiresDate + graceMs, now + ENTITLEMENT_MAX_SECONDS * 1000)
    await env.GuestUsage.getByName(`entitlement:${subject}`).setEntitlement(verified.originalTransactionId, validUntil)
  } else if (subscriptionRequired(env)
    && !await env.GuestUsage.getByName(`entitlement:${subject}`).entitlement(Date.now())) {
    return Response.json({ error: "subscription_required" }, { status: 402, headers: { "cache-control": "no-store" } })
  } else if (env.GUEST_BETA_ENABLED !== "true"
    && !await env.GuestUsage.getByName(`entitlement:${subject}`).entitlement(Date.now())) {
    return Response.json({ error: "Hosted guest access is temporarily unavailable." }, { status: 503 })
  }
  if (!await env.GuestUsage.getByName(`bootstrap:${ipID}`).consume(120)) {
    return Response.json({ error: "Hosted beta connection limit reached. Please try again tomorrow." }, { status: 429 })
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
  // Authoritative entitlement decision. Set only by guestSession() after a
  // signed App Store transaction verified; it expires on its own.
  const entitlement = await env.GuestUsage.getByName(`entitlement:${subject}`).entitlement(Date.now())
  if (entitlement) {
    // Budget is per subscription, so several bound guests cannot multiply it.
    if (!await env.GuestUsage.getByName(`turns:sub:${entitlement.originalTransactionId}`).consume(intVar(config.PAID_TURNS_PER_DAY, 150))) {
      throw new Error("You've reached today's Hosted limit for your subscription. Your course is saved. Please continue tomorrow.")
    }
    if (!await env.GuestUsage.getByName("turns:global:paid").consume(intVar(config.PAID_GLOBAL_TURNS_PER_DAY, 5000))) {
      throw new Error("Hosted has reached today's capacity. Your course is saved. Please continue tomorrow.")
    }
    return
  }
  if (subscriptionRequired(env)) {
    throw new Error("Hosted needs an active Learnfold Hosted subscription. Open Settings > Plan to subscribe, or choose another agent.")
  }
  if (env.GUEST_BETA_ENABLED !== "true") throw new Error("Hosted guest access is temporarily unavailable.")
  if (!await env.GuestUsage.getByName(`turns:${subject}`).consume(intVar(config.FREE_TURNS_PER_DAY, 60))) {
    throw new Error("You've reached today's Hosted beta limit. Your course is saved. Please continue tomorrow.")
  }
  if (!await env.GuestUsage.getByName("turns:global").consume(1000)) {
    throw new Error("Hosted has reached today's beta capacity. Your course is saved. Please continue tomorrow.")
  }
}
