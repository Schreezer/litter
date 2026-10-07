import { TEST_INTERMEDIATE_DER, TEST_LEAF_DER, TEST_LEAF_PKCS8, TEST_ROOT_DER } from "./apple-chain"

const b64url = (bytes: Uint8Array) => btoa(String.fromCharCode(...bytes)).replaceAll("+", "-").replaceAll("/", "_").replaceAll("=", "")
const encodeJson = (value: unknown) => b64url(new TextEncoder().encode(JSON.stringify(value)))

export type TestTransaction = Record<string, unknown>

export function transaction(overrides: TestTransaction = {}, now = Date.now()): TestTransaction {
  return {
    transactionId: String(Math.floor(Math.random() * 1e12)),
    originalTransactionId: String(Math.floor(Math.random() * 1e12)),
    bundleId: "com.chirag.learnfold",
    productId: "com.chirag.learnfold.hosted.monthly",
    type: "Auto-Renewable Subscription",
    environment: "Production",
    signedDate: now,
    purchaseDate: now - 86_400_000,
    expiresDate: now + 30 * 86_400_000,
    ...overrides,
  }
}

/** Signs `payload` like StoreKit: ES256 over header.payload with an x5c chain. */
export async function signTransaction(
  payload: TestTransaction,
  options: { chain?: string[]; alg?: string } = {},
): Promise<string> {
  const header = encodeJson({ alg: options.alg ?? "ES256", x5c: options.chain ?? [TEST_LEAF_DER, TEST_INTERMEDIATE_DER, TEST_ROOT_DER] })
  const body = encodeJson(payload)
  const key = await crypto.subtle.importKey(
    "pkcs8", Uint8Array.from(atob(TEST_LEAF_PKCS8), (c) => c.charCodeAt(0)), { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"],
  )
  const signature = new Uint8Array(await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, new TextEncoder().encode(`${header}.${body}`)))
  return `${header}.${body}.${b64url(signature)}`
}
