import { DurableObject } from "cloudflare:workers"

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/
const HEX_SECRET = /^[0-9a-f]{64}$/
const TOKEN_TTL_SECONDS = 3600

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
  if (env.GUEST_BETA_ENABLED !== "true" || !signingSecret) {
    return Response.json({ error: "Hosted guest access is temporarily unavailable." }, { status: 503 })
  }
  const secret = request.headers.get("authorization")?.match(/^Guest ([0-9a-f]{64})$/)?.[1]
  const session = new URL(request.url).searchParams.get("sessionId") ?? ""
  if (!secret || !UUID.test(session)) return Response.json({ error: "invalid_guest_session" }, { status: 400 })
  const ip = request.headers.get("cf-connecting-ip") ?? "local"
  const ipID = await hashIdentity(ip)
  if (!await env.GuestUsage.getByName(`bootstrap:${ipID}`).consume(120)) {
    return Response.json({ error: "Hosted is busy right now. Please try again tomorrow." }, { status: 429 })
  }
  const subject = await hashIdentity(secret)
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
  if (env.GUEST_BETA_ENABLED !== "true") throw new Error("Hosted guest access is temporarily unavailable.")
  if (!await env.GuestUsage.getByName(`turns:${subject}`).consume(60)) {
    throw new Error("You've reached today's Hosted usage limit. Your course is saved. Please continue tomorrow.")
  }
  if (!await env.GuestUsage.getByName("turns:global").consume(1000)) {
    throw new Error("Hosted has reached today's capacity. Your course is saved. Please continue tomorrow.")
  }
}
