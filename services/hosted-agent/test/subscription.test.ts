import { env } from "cloudflare:test"
import { describe, expect, it } from "vitest"

import { APPLE_ROOT_CA_G3_DER, APPLE_ROOT_CA_G3_SHA256, SubscriptionError, verifySignedTransaction } from "../src/app-store"
import { enforceGuestTurnLimit, guestSession, hashIdentity } from "../src/guest"
import { TEST_INTERMEDIATE_DER, TEST_LEAF_DER, TEST_LEAF_WITHOUT_MARKER_DER, TEST_ROOT_DER } from "./fixtures/apple-chain"
import { signTransaction, transaction } from "./fixtures/sign-transaction"

const HOSTED = "com.chirag.learnfold.hosted.monthly"
const options = {
  bundleId: "com.chirag.learnfold",
  products: { [HOSTED]: "hosted", "com.chirag.learnfold.hosted.yearly": "hosted" },
  trustedRootsDER: [TEST_ROOT_DER],
}

async function reason(promise: Promise<unknown>): Promise<string> {
  try {
    await promise
  } catch (error) {
    if (error instanceof SubscriptionError) return error.reason
    throw error
  }
  return "accepted"
}

describe("App Store signed transaction verification", () => {
  it("pins Apple's real root certificate", async () => {
    const digest = await crypto.subtle.digest("SHA-256", Uint8Array.from(atob(APPLE_ROOT_CA_G3_DER), (c) => c.charCodeAt(0)))
    expect(Array.from(new Uint8Array(digest), (b) => b.toString(16).padStart(2, "0")).join("")).toBe(APPLE_ROOT_CA_G3_SHA256)
  })

  it("accepts a valid active subscription", async () => {
    const payload = transaction({ originalTransactionId: "1000000123456789" })
    const verified = await verifySignedTransaction(await signTransaction(payload), options)
    expect(verified).toMatchObject({ productId: HOSTED, originalTransactionId: "1000000123456789", environment: "Production" })
  })

  it("accepts the chain without the root, anchored by the pinned root", async () => {
    const jws = await signTransaction(transaction(), { chain: [TEST_LEAF_DER, TEST_INTERMEDIATE_DER] })
    expect(await reason(verifySignedTransaction(jws, options))).toBe("accepted")
  })

  it("rejects a chain that does not end in a pinned Apple root", async () => {
    const jws = await signTransaction(transaction())
    expect(await reason(verifySignedTransaction(jws, { ...options, trustedRootsDER: [APPLE_ROOT_CA_G3_DER] }))).toBe("untrusted_chain")
  })

  it("rejects a self-built chain missing the App Store marker extensions", async () => {
    const jws = await signTransaction(transaction(), { chain: [TEST_LEAF_WITHOUT_MARKER_DER, TEST_INTERMEDIATE_DER, TEST_ROOT_DER] })
    expect(await reason(verifySignedTransaction(jws, options))).toBe("untrusted_chain")
  })

  it("rejects a broken chain order or a missing chain", async () => {
    expect(await reason(verifySignedTransaction(await signTransaction(transaction(), { chain: [TEST_INTERMEDIATE_DER, TEST_LEAF_DER, TEST_ROOT_DER] }), options))).toBe("untrusted_chain")
    expect(await reason(verifySignedTransaction(await signTransaction(transaction(), { chain: [TEST_LEAF_DER] }), options))).toBe("untrusted_chain")
  })

  it("rejects a tampered payload", async () => {
    const jws = await signTransaction(transaction())
    const [header, , signature] = jws.split(".")
    const forged = btoa(JSON.stringify(transaction({ expiresDate: Date.now() + 9e12 }))).replaceAll("=", "")
    expect(await reason(verifySignedTransaction(`${header}.${forged}.${signature}`, options))).toBe("bad_signature")
  })

  it("rejects unsupported algorithms and malformed input", async () => {
    expect(await reason(verifySignedTransaction(await signTransaction(transaction(), { alg: "none" }), options))).toBe("malformed")
    expect(await reason(verifySignedTransaction("not.a.jws", options))).toBe("malformed")
    expect(await reason(verifySignedTransaction("a.b", options))).toBe("malformed")
  })

  it("rejects the wrong bundle, unknown product and non-subscription types", async () => {
    expect(await reason(verifySignedTransaction(await signTransaction(transaction({ bundleId: "com.evil.app" })), options))).toBe("wrong_bundle")
    expect(await reason(verifySignedTransaction(await signTransaction(transaction({ productId: "com.chirag.learnfold.plus.monthly" })), options))).toBe("unknown_product")
    expect(await reason(verifySignedTransaction(await signTransaction(transaction({ type: "Consumable" })), options))).toBe("unknown_product")
  })

  it("rejects revoked transactions", async () => {
    const jws = await signTransaction(transaction({ revocationDate: Date.now() - 1000, revocationReason: 1 }))
    expect(await reason(verifySignedTransaction(jws, options))).toBe("revoked")
  })

  it("enforces expiry with an explicit grace window", async () => {
    const now = Date.now()
    const lapsed = await signTransaction(transaction({ expiresDate: now - 3_600_000 }, now))
    expect(await reason(verifySignedTransaction(lapsed, { ...options, now }))).toBe("expired")
    expect(await reason(verifySignedTransaction(lapsed, { ...options, now, graceMs: 86_400_000 }))).toBe("accepted")
    const longGone = await signTransaction(transaction({ expiresDate: now - 10 * 86_400_000 }, now))
    expect(await reason(verifySignedTransaction(longGone, { ...options, now, graceMs: 86_400_000 }))).toBe("expired")
  })

  it("filters environments: Sandbox is configurable, Xcode never verifies", async () => {
    const sandbox = await signTransaction(transaction({ environment: "Sandbox" }))
    expect(await reason(verifySignedTransaction(sandbox, options))).toBe("accepted")
    expect(await reason(verifySignedTransaction(sandbox, { ...options, acceptSandbox: false }))).toBe("unsupported_environment")
    expect(await reason(verifySignedTransaction(await signTransaction(transaction({ environment: "Xcode" })), options))).toBe("unsupported_environment")
  })

  it("rejects transactions signed in the future", async () => {
    const jws = await signTransaction(transaction({ signedDate: Date.now() + 3_600_000 }))
    expect(await reason(verifySignedTransaction(jws, options))).toBe("malformed")
  })
})

type Overrides = Record<string, string>
const testEnv = (overrides: Overrides = {}) => ({ ...env, APPLE_ROOT_CAS_DER: TEST_ROOT_DER, ...overrides }) as unknown as Env

async function exchange(secret: string, overrides: Overrides, signedTransaction?: string): Promise<Response> {
  return guestSession(new Request(`https://agent.test/guest-session?sessionId=${crypto.randomUUID()}`, {
    method: "POST",
    headers: { authorization: `Guest ${secret}`, ...(signedTransaction ? { "content-type": "application/json" } : {}) },
    body: signedTransaction ? JSON.stringify({ signedTransaction }) : undefined,
  }), testEnv(overrides), "test-access-token")
}

const guestName = async (secret: string) => `guest-${await hashIdentity(secret)}-${crypto.randomUUID()}`
const randomSecret = () => Array.from(crypto.getRandomValues(new Uint8Array(32)), (b) => b.toString(16).padStart(2, "0")).join("")

describe("subscription-aware guest sessions", () => {
  it("keeps the free guest path unchanged while the flag is off", async () => {
    const secret = randomSecret()
    expect((await exchange(secret, {})).status).toBe(200)
    await expect(enforceGuestTurnLimit(await guestName(secret), testEnv())).resolves.toBeUndefined()
  })

  it("requires a verified subscription when REQUIRE_SUBSCRIPTION is true", async () => {
    const secret = randomSecret()
    const response = await exchange(secret, { REQUIRE_SUBSCRIPTION: "true" })
    expect(response.status).toBe(402)
    expect(await response.json()).toEqual({ error: "subscription_required" })
    await expect(enforceGuestTurnLimit(await guestName(secret), testEnv({ REQUIRE_SUBSCRIPTION: "true" })))
      .rejects.toThrow("active Learnfold Hosted subscription")
  })

  it("mints a token and unlocks turns after verifying a signed transaction", async () => {
    const secret = randomSecret()
    const jws = await signTransaction(transaction({ originalTransactionId: String(Date.now()) }))
    const response = await exchange(secret, { REQUIRE_SUBSCRIPTION: "true" }, jws)
    expect(response.status).toBe(200)
    expect((await response.json<{ accessToken: string }>()).accessToken).toMatch(/^guest-v1\./)
    const required = testEnv({ REQUIRE_SUBSCRIPTION: "true" })
    await expect(enforceGuestTurnLimit(await guestName(secret), required)).resolves.toBeUndefined()
    // The entitlement is server state: a later exchange without a transaction still works.
    expect((await exchange(secret, { REQUIRE_SUBSCRIPTION: "true" })).status).toBe(200)
    // It does not leak to another guest identity.
    await expect(enforceGuestTurnLimit(await guestName(randomSecret()), required)).rejects.toThrow("subscription")
  })

  it("rejects invalid, revoked and wrong-product transactions with 402", async () => {
    for (const payload of [{ bundleId: "com.evil.app" }, { revocationDate: Date.now() - 5 }, { productId: "com.chirag.learnfold.plus.monthly" }]) {
      const response = await exchange(randomSecret(), {}, await signTransaction(transaction(payload)))
      expect(response.status).toBe(402)
      expect((await response.json<{ error: string }>()).error).toBe("subscription_invalid")
    }
    expect((await exchange(randomSecret(), {}, "garbage")).status).toBe(402)
  })

  it("replaces the daily free limit with the paid budget, keyed by subscription", async () => {
    const original = String(Date.now() + 1)
    const overrides = { PAID_TURNS_PER_DAY: "2", FREE_TURNS_PER_DAY: "1" }
    const jws = await signTransaction(transaction({ originalTransactionId: original }))
    const first = randomSecret()
    const second = randomSecret()
    expect((await exchange(first, overrides, jws)).status).toBe(200)
    expect((await exchange(second, overrides, jws)).status).toBe(200)
    const config = testEnv(overrides)
    await enforceGuestTurnLimit(await guestName(first), config)
    await enforceGuestTurnLimit(await guestName(second), config)
    // Two devices share one budget of two turns.
    await expect(enforceGuestTurnLimit(await guestName(first), config)).rejects.toThrow("subscription")
  })

  it("limits how many guest identities one subscription can bind", async () => {
    const jws = await signTransaction(transaction({ originalTransactionId: String(Date.now() + 2) }))
    const overrides = { MAX_GUESTS_PER_SUBSCRIPTION: "2" }
    expect((await exchange(randomSecret(), overrides, jws)).status).toBe(200)
    expect((await exchange(randomSecret(), overrides, jws)).status).toBe(200)
    const third = await exchange(randomSecret(), overrides, jws)
    expect(third.status).toBe(409)
    expect((await third.json<{ error: string }>()).error).toBe("subscription_in_use")
  })

  it("lets subscribers through when the free beta is switched off", async () => {
    const secret = randomSecret()
    const off = { GUEST_BETA_ENABLED: "false" }
    expect((await exchange(randomSecret(), off)).status).toBe(503)
    const jws = await signTransaction(transaction({ originalTransactionId: String(Date.now() + 3) }))
    expect((await exchange(secret, off, jws)).status).toBe(200)
    await expect(enforceGuestTurnLimit(await guestName(secret), testEnv(off))).resolves.toBeUndefined()
  })
})
