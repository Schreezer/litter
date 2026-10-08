import { env } from "cloudflare:test"
import { afterEach, describe, expect, it, vi } from "vitest"

import { enforceGuestTurnLimit, guestSession, hashIdentity, resolveEntitlement, revenueCatWebhook } from "../src/guest"
import { revenueCatAppUserId } from "../src/revenuecat"

// RevenueCat is always mocked. Nothing in this file may reach the real API.
const KEY = "sk_test_not_a_real_key"
const WEBHOOK_SECRET = "webhook-secret-for-tests"
const HOUR = 3_600_000
const DAY = 24 * HOUR

type Overrides = Record<string, string>
const testEnv = (overrides: Overrides = {}) =>
  ({ ...env, REVENUECAT_SECRET_API_KEY: KEY, REVENUECAT_WEBHOOK_SECRET: WEBHOOK_SECRET, ...overrides }) as unknown as Env

const randomSecret = () => Array.from(crypto.getRandomValues(new Uint8Array(32)), (b) => b.toString(16).padStart(2, "0")).join("")
const guestName = async (secret: string) => `guest-${await hashIdentity(secret)}-${crypto.randomUUID()}`

type Entitlement = { expires_date: string | null; grace_period_expires_date?: string | null; product_identifier: string }
type Subscription = { is_sandbox?: boolean; refunded_at?: string | null; store?: string }

function subscriberBody(options: {
  entitlements?: Record<string, Entitlement>
  subscriptions?: Record<string, Subscription>
  original?: string
}) {
  return {
    request_date_ms: Date.now(),
    subscriber: {
      original_app_user_id: options.original ?? `lf1_${randomSecret()}`,
      entitlements: options.entitlements ?? {},
      subscriptions: options.subscriptions ?? {},
    },
  }
}

const HOSTED_PRODUCT = "com.chirag.learnfold.hosted.monthly"
const iso = (offsetMs: number) => new Date(Date.now() + offsetMs).toISOString()

function hostedBody(options: { expires?: number | null; grace?: number; sandbox?: boolean; refunded?: boolean; original?: string } = {}) {
  return subscriberBody({
    original: options.original,
    entitlements: {
      hosted: {
        expires_date: options.expires === null ? null : iso(options.expires ?? 30 * DAY),
        grace_period_expires_date: options.grace === undefined ? null : iso(options.grace),
        product_identifier: HOSTED_PRODUCT,
      },
    },
    subscriptions: {
      [HOSTED_PRODUCT]: { is_sandbox: options.sandbox ?? false, refunded_at: options.refunded ? iso(-HOUR) : null, store: "app_store" },
    },
  })
}

type Handler = (url: URL, init: RequestInit | undefined) => Response | Promise<Response>
function mockRevenueCat(handler: Handler) {
  const spy = vi.spyOn(globalThis, "fetch").mockImplementation(async (input, init) => {
    const url = new URL(typeof input === "string" ? input : input instanceof URL ? input.href : (input as Request).url)
    if (url.hostname !== "api.revenuecat.com") throw new Error(`unexpected network call to ${url.href}`)
    return handler(url, init)
  })
  return spy
}
const answer = (body: unknown, status = 200) => () => Response.json(body, { status })

afterEach(() => vi.restoreAllMocks())

async function exchange(secret: string, overrides: Overrides = {}): Promise<Response> {
  return guestSession(new Request(`https://agent.test/guest-session?sessionId=${crypto.randomUUID()}`, {
    method: "POST",
    headers: { authorization: `Guest ${secret}` },
  }), testEnv(overrides), "test-access-token")
}

describe("RevenueCat app user id", () => {
  it("is a one-way, domain-separated hash pinned by a shared test vector", async () => {
    // The same vector is asserted by HostedGuestIdentityTests on iOS.
    const secret = "0123456789abcdef".repeat(4)
    expect(await revenueCatAppUserId(secret)).toBe("lf1_66f345ab9622be22e4a3762e6d7609f6da48c3e45ca3bb1df0246e943d6e0756")
    const id = await revenueCatAppUserId(randomSecret())
    expect(id).toMatch(/^lf1_[0-9a-f]{64}$/)
  })

  it("never contains the secret and differs from the conversation namespace hash", async () => {
    const secret = randomSecret()
    const id = await revenueCatAppUserId(secret)
    expect(id).not.toContain(secret)
    expect(id).not.toContain(await hashIdentity(secret))
  })
})

describe("RevenueCat-backed guest sessions", () => {
  it("does not call RevenueCat and keeps the free path when no secret key is configured", async () => {
    const spy = mockRevenueCat(answer(hostedBody()))
    const secret = randomSecret()
    expect((await exchange(secret, { REVENUECAT_SECRET_API_KEY: "" })).status).toBe(200)
    await expect(enforceGuestTurnLimit(await guestName(secret), testEnv({ REVENUECAT_SECRET_API_KEY: "" }))).resolves.toBeUndefined()
    expect(spy).not.toHaveBeenCalled()
  })

  it("asks RevenueCat about the derived id with the secret key, never the guest secret", async () => {
    const secret = randomSecret()
    const calls: { url: URL; init: RequestInit | undefined }[] = []
    mockRevenueCat((url, init) => {
      calls.push({ url, init })
      return Response.json(subscriberBody({}))
    })
    expect((await exchange(secret)).status).toBe(200)
    expect(calls).toHaveLength(1)
    const expectedId = await revenueCatAppUserId(secret)
    expect(calls[0].url.href).toBe(`https://api.revenuecat.com/v1/subscribers/${expectedId}`)
    expect((calls[0].init?.headers as Record<string, string>).authorization).toBe(`Bearer ${KEY}`)
    expect(calls[0].url.href).not.toContain(secret)
    expect(JSON.stringify(calls[0].init)).not.toContain(secret)
  })

  it("requires the hosted entitlement when REQUIRE_SUBSCRIPTION is true", async () => {
    mockRevenueCat(answer(subscriberBody({})))
    const secret = randomSecret()
    const response = await exchange(secret, { REQUIRE_SUBSCRIPTION: "true" })
    expect(response.status).toBe(402)
    expect(await response.json()).toEqual({ error: "subscription_required" })
    await expect(enforceGuestTurnLimit(await guestName(secret), testEnv({ REQUIRE_SUBSCRIPTION: "true" })))
      .rejects.toThrow("active Learnfold Hosted subscription")
  })

  it("mints a token and unlocks turns for an active entitlement, without leaking to other guests", async () => {
    const secret = randomSecret()
    const mine = await revenueCatAppUserId(secret)
    mockRevenueCat((url) => Response.json(url.pathname.endsWith(mine) ? hostedBody({ original: mine }) : subscriberBody({})))
    const required = { REQUIRE_SUBSCRIPTION: "true" }
    const response = await exchange(secret, required)
    expect(response.status).toBe(200)
    expect((await response.json<{ accessToken: string }>()).accessToken).toMatch(/^guest-v1\./)
    await expect(enforceGuestTurnLimit(await guestName(secret), testEnv(required))).resolves.toBeUndefined()
    // Another install presenting its own secret is looked up under its own id and gets nothing.
    const other = randomSecret()
    expect((await exchange(other, required)).status).toBe(402)
    await expect(enforceGuestTurnLimit(await guestName(other), testEnv(required))).rejects.toThrow("subscription")
  })

  it("ignores a plus-only customer: hosted needs the hosted entitlement", async () => {
    mockRevenueCat(answer(subscriberBody({
      entitlements: { plus: { expires_date: iso(DAY), product_identifier: "com.chirag.learnfold.plus.monthly" } },
    })))
    expect((await exchange(randomSecret(), { REQUIRE_SUBSCRIPTION: "true" })).status).toBe(402)
  })

  it("rejects an expired entitlement, honours billing grace, and allows non-expiring grants", async () => {
    mockRevenueCat(answer(hostedBody({ expires: -2 * HOUR })))
    expect((await exchange(randomSecret(), { REQUIRE_SUBSCRIPTION: "true" })).status).toBe(402)
    vi.restoreAllMocks()

    mockRevenueCat(answer(hostedBody({ expires: -2 * HOUR, grace: 2 * DAY })))
    expect((await exchange(randomSecret(), { REQUIRE_SUBSCRIPTION: "true" })).status).toBe(200)
    vi.restoreAllMocks()

    mockRevenueCat(answer(hostedBody({ expires: -2 * HOUR, grace: -HOUR })))
    expect((await exchange(randomSecret(), { REQUIRE_SUBSCRIPTION: "true" })).status).toBe(402)
    vi.restoreAllMocks()

    mockRevenueCat(answer(hostedBody({ expires: null })))
    expect((await exchange(randomSecret(), { REQUIRE_SUBSCRIPTION: "true" })).status).toBe(200)
  })

  it("rejects refunded subscriptions", async () => {
    mockRevenueCat(answer(hostedBody({ refunded: true })))
    expect((await exchange(randomSecret(), { REQUIRE_SUBSCRIPTION: "true" })).status).toBe(402)
  })

  it("accepts sandbox purchases by default and rejects them when ACCEPT_SANDBOX_TRANSACTIONS is false", async () => {
    mockRevenueCat(answer(hostedBody({ sandbox: true })))
    expect((await exchange(randomSecret(), { REQUIRE_SUBSCRIPTION: "true" })).status).toBe(200)
    expect((await exchange(randomSecret(), { REQUIRE_SUBSCRIPTION: "true", ACCEPT_SANDBOX_TRANSACTIONS: "true" })).status).toBe(200)
    expect((await exchange(randomSecret(), { REQUIRE_SUBSCRIPTION: "true", ACCEPT_SANDBOX_TRANSACTIONS: "false" })).status).toBe(402)
  })

  it("answers 503, not 402, when RevenueCat cannot be asked and a subscription is required", async () => {
    for (const handler of [answer({}, 500), answer({ message: "bad key" }, 401), answer({}, 429), () => { throw new TypeError("network down") }, () => new Response("not json")]) {
      mockRevenueCat(handler)
      const secret = randomSecret()
      const response = await exchange(secret, { REQUIRE_SUBSCRIPTION: "true" })
      expect(response.status).toBe(503)
      expect(await response.json()).toEqual({ error: "subscription_unverifiable" })
      vi.restoreAllMocks()
    }
  })

  it("lets free guests through a RevenueCat outage while the flag is off", async () => {
    mockRevenueCat(answer({}, 500))
    expect((await exchange(randomSecret())).status).toBe(200)
  })

  it("keeps a recently confirmed subscriber working through an outage, but not forever", async () => {
    const secret = randomSecret()
    const subject = await hashIdentity(secret)
    const id = await revenueCatAppUserId(secret)
    const spy = mockRevenueCat(answer(hostedBody({ original: id })))
    const required = testEnv({ REQUIRE_SUBSCRIPTION: "true", REVENUECAT_CACHE_SECONDS: "60" })
    const t0 = Date.now()
    expect((await resolveEntitlement(required, subject, id, t0)).kind).toBe("entitled")
    spy.mockImplementation(async () => new Response("down", { status: 500 }))
    // Cache expired, RevenueCat down, confirmed 10 minutes ago: still entitled.
    expect((await resolveEntitlement(required, subject, id, t0 + 10 * 60_000)).kind).toBe("entitled")
    // Confirmed more than an hour ago: no longer trusted.
    expect((await resolveEntitlement(required, subject, id, t0 + 2 * HOUR)).kind).toBe("unavailable")
  })
})

describe("entitlement cache", () => {
  it("serves repeated exchanges from the cache and refreshes after the TTL", async () => {
    const secret = randomSecret()
    const subject = await hashIdentity(secret)
    const id = await revenueCatAppUserId(secret)
    const spy = mockRevenueCat(answer(hostedBody({ original: id })))
    const config = testEnv({ REQUIRE_SUBSCRIPTION: "true" })
    const t0 = Date.now()
    expect((await resolveEntitlement(config, subject, id, t0)).kind).toBe("entitled")
    expect((await resolveEntitlement(config, subject, id, t0 + 5 * 60_000)).kind).toBe("entitled")
    expect(spy).toHaveBeenCalledTimes(1)
    expect((await resolveEntitlement(config, subject, id, t0 + 16 * 60_000)).kind).toBe("entitled")
    expect(spy).toHaveBeenCalledTimes(2)
  })

  it("never trusts RevenueCat answers for more than 15 minutes, whatever the config says", async () => {
    const secret = randomSecret()
    const subject = await hashIdentity(secret)
    const id = await revenueCatAppUserId(secret)
    const spy = mockRevenueCat(answer(hostedBody({ original: id })))
    const config = testEnv({ REVENUECAT_CACHE_SECONDS: "999999" })
    const t0 = Date.now()
    await resolveEntitlement(config, subject, id, t0)
    await resolveEntitlement(config, subject, id, t0 + 16 * 60_000)
    expect(spy).toHaveBeenCalledTimes(2)
  })

  it("caches a no-entitlement answer only briefly", async () => {
    const secret = randomSecret()
    const subject = await hashIdentity(secret)
    const id = await revenueCatAppUserId(secret)
    const spy = mockRevenueCat(answer(subscriberBody({})))
    const config = testEnv()
    const t0 = Date.now()
    expect((await resolveEntitlement(config, subject, id, t0)).kind).toBe("free")
    expect((await resolveEntitlement(config, subject, id, t0 + 30_000)).kind).toBe("free")
    expect(spy).toHaveBeenCalledTimes(1)
    expect((await resolveEntitlement(config, subject, id, t0 + 61_000)).kind).toBe("free")
    expect(spy).toHaveBeenCalledTimes(2)
  })

  it("re-checks a lapsed subscriber on the next turn instead of trusting the old grant", async () => {
    const secret = randomSecret()
    const subject = await hashIdentity(secret)
    const id = await revenueCatAppUserId(secret)
    const spy = mockRevenueCat(answer(hostedBody({ original: id })))
    const required = testEnv({ REQUIRE_SUBSCRIPTION: "true", REVENUECAT_CACHE_SECONDS: "0" })
    expect((await exchange(secret, { REQUIRE_SUBSCRIPTION: "true", REVENUECAT_CACHE_SECONDS: "0" })).status).toBe(200)
    await expect(enforceGuestTurnLimit(await guestName(secret), required)).resolves.toBeUndefined()
    spy.mockImplementation(async () => Response.json(subscriberBody({})))
    await expect(enforceGuestTurnLimit(await guestName(secret), required)).rejects.toThrow("subscription")
  })
})

describe("per-subscription budget and guest binding", () => {
  it("shares one paid budget across guests that RevenueCat reports under one customer", async () => {
    const original = `lf1_${"b".repeat(64)}`
    mockRevenueCat(answer(hostedBody({ original })))
    const overrides = { PAID_TURNS_PER_DAY: "2", FREE_TURNS_PER_DAY: "1" }
    const first = randomSecret()
    const second = randomSecret()
    expect((await exchange(first, overrides)).status).toBe(200)
    expect((await exchange(second, overrides)).status).toBe(200)
    const config = testEnv(overrides)
    await enforceGuestTurnLimit(await guestName(first), config)
    await enforceGuestTurnLimit(await guestName(second), config)
    await expect(enforceGuestTurnLimit(await guestName(first), config)).rejects.toThrow("subscription")
  })

  it("limits how many guest identities one customer can bind", async () => {
    const original = `lf1_${"c".repeat(64)}`
    mockRevenueCat(answer(hostedBody({ original })))
    const overrides = { MAX_GUESTS_PER_SUBSCRIPTION: "2" }
    expect((await exchange(randomSecret(), overrides)).status).toBe(200)
    expect((await exchange(randomSecret(), overrides)).status).toBe(200)
    const third = await exchange(randomSecret(), overrides)
    expect(third.status).toBe(409)
    expect((await third.json<{ error: string }>()).error).toBe("subscription_in_use")
  })

  it("lets subscribers through when the free beta is switched off", async () => {
    mockRevenueCat(answer(hostedBody()))
    const off = { GUEST_BETA_ENABLED: "false" }
    const subscriber = randomSecret()
    expect((await exchange(subscriber, off)).status).toBe(200)
    await expect(enforceGuestTurnLimit(await guestName(subscriber), testEnv(off))).resolves.toBeUndefined()
    vi.restoreAllMocks()
    mockRevenueCat(answer(subscriberBody({})))
    expect((await exchange(randomSecret(), off)).status).toBe(503)
  })
})

describe("RevenueCat webhook", () => {
  const event = (type: string, ids: string[], extra: Record<string, unknown> = {}) => ({
    api_version: "1.0",
    event: { type, app_user_id: ids[0], original_app_user_id: ids[0], aliases: ids, ...extra },
  })
  const post = (body: unknown, authorization?: string, config = testEnv()) =>
    revenueCatWebhook(new Request("https://agent.test/revenuecat/webhook", {
      method: "POST",
      headers: authorization ? { authorization } : {},
      body: typeof body === "string" ? body : JSON.stringify(body),
    }), config)

  it("rejects missing, wrong and unconfigured credentials", async () => {
    expect((await post(event("INITIAL_PURCHASE", []))).status).toBe(401)
    expect((await post(event("INITIAL_PURCHASE", []), "wrong")).status).toBe(401)
    expect((await post(event("INITIAL_PURCHASE", []), `Bearer ${WEBHOOK_SECRET}x`)).status).toBe(401)
    expect((await post(event("INITIAL_PURCHASE", []), WEBHOOK_SECRET, testEnv({ REVENUECAT_WEBHOOK_SECRET: "" }))).status).toBe(401)
  })

  it("accepts the secret verbatim or as a Bearer token, and rejects malformed bodies", async () => {
    mockRevenueCat(answer(subscriberBody({})))
    expect((await post(event("TEST", []), WEBHOOK_SECRET)).status).toBe(200)
    expect((await post(event("TEST", []), `Bearer ${WEBHOOK_SECRET}`)).status).toBe(200)
    expect((await post("{not json", WEBHOOK_SECRET)).status).toBe(400)
    expect((await post({ nope: true }, WEBHOOK_SECRET)).status).toBe(400)
  })

  it("refreshes a purchaser immediately and revokes on expiration", async () => {
    const secret = randomSecret()
    const subject = await hashIdentity(secret)
    const id = await revenueCatAppUserId(secret)
    const spy = mockRevenueCat(answer(subscriberBody({})))
    const required = { REQUIRE_SUBSCRIPTION: "true" }
    // The guest connected before paying: cached as not entitled.
    expect((await exchange(secret, required)).status).toBe(402)
    expect(await env.GuestUsage.getByName(`entitlement:${subject}`).cachedEntitlement()).toMatchObject({ entitled: false })

    spy.mockImplementation(async () => Response.json(hostedBody({ original: id })))
    const purchased = await post(event("INITIAL_PURCHASE", [id]), WEBHOOK_SECRET)
    expect(await purchased.json()).toEqual({ ok: true, refreshed: 1 })
    expect(await env.GuestUsage.getByName(`entitlement:${subject}`).cachedEntitlement()).toMatchObject({ entitled: true, originalAppUserId: id })
    await expect(enforceGuestTurnLimit(await guestName(secret), testEnv(required))).resolves.toBeUndefined()

    spy.mockImplementation(async () => Response.json(subscriberBody({})))
    await post(event("EXPIRATION", [id], { expiration_reason: "UNSUBSCRIBE" }), WEBHOOK_SECRET)
    expect(await env.GuestUsage.getByName(`entitlement:${subject}`).cachedEntitlement()).toMatchObject({ entitled: false })
    await expect(enforceGuestTurnLimit(await guestName(secret), testEnv(required))).rejects.toThrow("subscription")
  })

  it("drops the cached grant after a terminal event even if RevenueCat cannot be read", async () => {
    for (const type of ["EXPIRATION", "CANCELLATION", "BILLING_ISSUE", "REFUND"]) {
      const secret = randomSecret()
      const subject = await hashIdentity(secret)
      const id = await revenueCatAppUserId(secret)
      const spy = mockRevenueCat(answer(hostedBody({ original: id })))
      expect((await exchange(secret)).status).toBe(200)
      expect(await env.GuestUsage.getByName(`entitlement:${subject}`).cachedEntitlement()).toMatchObject({ entitled: true })
      spy.mockImplementation(async () => new Response("down", { status: 500 }))
      await post(event(type, [id]), WEBHOOK_SECRET)
      expect(await env.GuestUsage.getByName(`entitlement:${subject}`).cachedEntitlement()).toBeNull()
      vi.restoreAllMocks()
    }
  })

  it("leaves the cache alone on a non-terminal event when RevenueCat cannot be read", async () => {
    const secret = randomSecret()
    const subject = await hashIdentity(secret)
    const id = await revenueCatAppUserId(secret)
    const spy = mockRevenueCat(answer(hostedBody({ original: id })))
    await exchange(secret)
    spy.mockImplementation(async () => new Response("down", { status: 500 }))
    await post(event("RENEWAL", [id]), WEBHOOK_SECRET)
    expect(await env.GuestUsage.getByName(`entitlement:${subject}`).cachedEntitlement()).toMatchObject({ entitled: true })
  })

  it("ignores users that never opened a Hosted session and ids it did not derive", async () => {
    const spy = mockRevenueCat(answer(subscriberBody({})))
    const stranger = await revenueCatAppUserId(randomSecret())
    expect(await (await post(event("RENEWAL", [stranger, "$RCAnonymousID:abc", "someone@example.com"]), WEBHOOK_SECRET)).json())
      .toEqual({ ok: true, refreshed: 0 })
    expect(spy).not.toHaveBeenCalled()
  })
})
