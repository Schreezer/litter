// Offline verification of App Store signed transactions (StoreKit 2 JWS).
//
// A signed transaction is an ES256 JWS whose header carries an x5c chain
// (leaf, intermediate, root). We verify, entirely locally and without calling
// Apple: the chain terminates in a pinned Apple root, each certificate is
// signed by the next and valid, the leaf and intermediate carry Apple's marker
// OIDs, the JWS signature verifies under the leaf key, and the payload names
// our bundle, a known product, no revocation, and an unexpired subscription.

export const APPLE_ROOT_CA_G3_DER =
  "MIICQzCCAcmgAwIBAgIILcX8iNLFS5UwCgYIKoZIzj0EAwMwZzEbMBkGA1UEAwwSQXBwbGUgUm9vdCBDQSAtIEczMSYwJAYDVQQLDB1BcHBsZSBDZXJ0aWZpY2F0aW9uIEF1dGhvcml0eTETMBEGA1UECgwKQXBwbGUgSW5jLjELMAkGA1UEBhMCVVMwHhcNMTQwNDMwMTgxOTA2WhcNMzkwNDMwMTgxOTA2WjBnMRswGQYDVQQDDBJBcHBsZSBSb290IENBIC0gRzMxJjAkBgNVBAsMHUFwcGxlIENlcnRpZmljYXRpb24gQXV0aG9yaXR5MRMwEQYDVQQKDApBcHBsZSBJbmMuMQswCQYDVQQGEwJVUzB2MBAGByqGSM49AgEGBSuBBAAiA2IABJjpLz1AcqTtkyJygRMc3RCV8cWjTnHcFBbZDuWmBSp3ZHtfTjjTuxxEtX/1H7YyYl3J6YRbTzBPEVoA/VhYDKX1DyxNB0cTddqXl5dvMVztK517IDvYuVTZXpmkOlEKMaNCMEAwHQYDVR0OBBYEFLuw3qFYM4iapIqZ3r6966/ayySrMA8GA1UdEwEB/wQFMAMBAf8wDgYDVR0PAQH/BAQDAgEGMAoGCCqGSM49BAMDA2gAMGUCMQCD6cHEFl4aXTQY2e3v9GwOAEZLuN+yRhHFD/3meoyhpmvOwgPUnPWTxnS4at+qIxUCMG1mihDK1A3UT82NQz60imOlM27jbdoXt2QfyFMm+YhidDkLF1vLUagM6BgD56KyKA=="
// SHA-256 of the DER above, from Apple's published "Apple Root CA - G3".
export const APPLE_ROOT_CA_G3_SHA256 = "63343abfb89a6a03ebb57e9b3f5fa7be7c4f5c756f3017b3a8c488c3653e9179"

const LEAF_MARKER_OID = "1.2.840.113635.100.6.11.1" // Mac App Store receipt signing
const INTERMEDIATE_MARKER_OID = "1.2.840.113635.100.6.2.1" // WWDR intermediate
const SIGNED_DATE_FUTURE_SKEW_MS = 5 * 60 * 1000

export type SubscriptionRejection =
  | "malformed"
  | "untrusted_chain"
  | "bad_signature"
  | "wrong_bundle"
  | "unknown_product"
  | "revoked"
  | "expired"
  | "unsupported_environment"

export class SubscriptionError extends Error {
  constructor(readonly reason: SubscriptionRejection, message?: string) {
    super(message ?? reason)
  }
}

export type VerifiedTransaction = {
  productId: string
  originalTransactionId: string
  expiresDate: number
  environment: string
  signedDate: number
}

export type VerifyOptions = {
  bundleId: string
  /** product id -> tier */
  products: Record<string, string>
  trustedRootsDER?: string[]
  acceptSandbox?: boolean
  /** Apple's billing-retry grace: a lapsed transaction is honored this long. */
  graceMs?: number
  now?: number
}

// ---- minimal DER ----------------------------------------------------------

type Tlv = { tag: number; start: number; header: number; end: number }

function readTlv(bytes: Uint8Array, offset: number): Tlv {
  if (offset + 2 > bytes.length) throw new SubscriptionError("malformed")
  const tag = bytes[offset]
  let length = bytes[offset + 1]
  let header = 2
  if (length & 0x80) {
    const count = length & 0x7f
    if (count < 1 || count > 3 || offset + 2 + count > bytes.length) throw new SubscriptionError("malformed")
    length = 0
    for (let i = 0; i < count; i += 1) length = length * 256 + bytes[offset + 2 + i]
    header = 2 + count
  }
  const end = offset + header + length
  if (end > bytes.length) throw new SubscriptionError("malformed")
  return { tag, start: offset, header, end }
}

function children(bytes: Uint8Array, parent: Tlv): Tlv[] {
  const out: Tlv[] = []
  let cursor = parent.start + parent.header
  while (cursor < parent.end) {
    const child = readTlv(bytes, cursor)
    out.push(child)
    cursor = child.end
  }
  return out
}

const slice = (bytes: Uint8Array, tlv: Tlv) => bytes.slice(tlv.start, tlv.end)
const body = (bytes: Uint8Array, tlv: Tlv) => bytes.slice(tlv.start + tlv.header, tlv.end)

function encodeOid(oid: string): Uint8Array {
  const parts = oid.split(".").map(Number)
  const out = [parts[0] * 40 + parts[1]]
  for (const part of parts.slice(2)) {
    const chunk = [part & 0x7f]
    for (let rest = Math.floor(part / 128); rest > 0; rest = Math.floor(rest / 128)) chunk.unshift((rest & 0x7f) | 0x80)
    out.push(...chunk)
  }
  return Uint8Array.from([0x06, out.length, ...out])
}

function decodeOid(bytes: Uint8Array): string {
  const parts = [Math.floor(bytes[0] / 40), bytes[0] % 40]
  let value = 0
  for (const byte of bytes.slice(1)) {
    value = value * 128 + (byte & 0x7f)
    if (!(byte & 0x80)) { parts.push(value); value = 0 }
  }
  return parts.join(".")
}

function contains(haystack: Uint8Array, needle: Uint8Array): boolean {
  outer: for (let i = 0; i + needle.length <= haystack.length; i += 1) {
    for (let j = 0; j < needle.length; j += 1) if (haystack[i + j] !== needle[j]) continue outer
    return true
  }
  return false
}

function equal(a: Uint8Array, b: Uint8Array): boolean {
  return a.length === b.length && a.every((value, index) => value === b[index])
}

function parseTime(bytes: Uint8Array, tlv: Tlv): number {
  const text = new TextDecoder().decode(body(bytes, tlv))
  const match = tlv.tag === 0x17
    ? text.match(/^(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})Z$/)
    : text.match(/^(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})Z$/)
  if (!match) throw new SubscriptionError("malformed")
  let year = Number(match[1])
  if (tlv.tag === 0x17) year += year >= 50 ? 1900 : 2000
  return Date.UTC(year, Number(match[2]) - 1, Number(match[3]), Number(match[4]), Number(match[5]), Number(match[6]))
}

type Certificate = {
  der: Uint8Array
  tbs: Uint8Array
  issuer: Uint8Array
  subject: Uint8Array
  spki: Uint8Array
  curve: "P-256" | "P-384"
  notBefore: number
  notAfter: number
  hash: "SHA-256" | "SHA-384"
  signature: Uint8Array // DER ECDSA-Sig-Value
}

const CURVES: Record<string, "P-256" | "P-384"> = { "1.2.840.10045.3.1.7": "P-256", "1.3.132.0.34": "P-384" }
const HASHES: Record<string, "SHA-256" | "SHA-384"> = { "1.2.840.10045.4.3.2": "SHA-256", "1.2.840.10045.4.3.3": "SHA-384" }

function parseCertificate(der: Uint8Array): Certificate {
  const cert = readTlv(der, 0)
  if (cert.tag !== 0x30 || cert.end !== der.length) throw new SubscriptionError("malformed")
  const [tbsTlv, sigAlg, sigValue] = children(der, cert)
  if (!tbsTlv || !sigAlg || !sigValue || sigValue.tag !== 0x03) throw new SubscriptionError("malformed")
  const fields = children(der, tbsTlv)
  const offset = fields[0].tag === 0xa0 ? 1 : 0 // optional [0] version
  const validity = children(der, fields[offset + 3])
  const spkiTlv = fields[offset + 5]
  const algorithm = children(der, children(der, spkiTlv)[0])
  const curve = CURVES[decodeOid(body(der, algorithm[1]))]
  const hash = HASHES[decodeOid(body(der, children(der, sigAlg)[0]))]
  if (!curve || !hash) throw new SubscriptionError("untrusted_chain", "unsupported certificate algorithm")
  return {
    der,
    tbs: slice(der, tbsTlv),
    issuer: slice(der, fields[offset + 2]),
    subject: slice(der, fields[offset + 4]),
    spki: slice(der, spkiTlv),
    curve,
    notBefore: parseTime(der, validity[0]),
    notAfter: parseTime(der, validity[1]),
    hash,
    signature: body(der, sigValue).slice(1), // drop unused-bits byte
  }
}

/** DER ECDSA-Sig-Value -> fixed-width r||s as WebCrypto expects. */
function rawSignature(der: Uint8Array, size: number): Uint8Array {
  const sequence = readTlv(der, 0)
  const [r, s] = children(der, sequence)
  if (sequence.tag !== 0x30 || !r || !s || r.tag !== 0x02 || s.tag !== 0x02) throw new SubscriptionError("malformed")
  const out = new Uint8Array(size * 2)
  for (const [index, part] of [r, s].entries()) {
    let value = body(der, part)
    while (value.length > size && value[0] === 0) value = value.slice(1)
    if (value.length > size) throw new SubscriptionError("malformed")
    out.set(value, index * size + size - value.length)
  }
  return out
}

async function verifySignedBy(cert: Certificate, issuer: Certificate): Promise<boolean> {
  const size = issuer.curve === "P-256" ? 32 : 48
  const key = await crypto.subtle.importKey("spki", issuer.spki, { name: "ECDSA", namedCurve: issuer.curve }, false, ["verify"])
  return crypto.subtle.verify({ name: "ECDSA", hash: cert.hash }, key, rawSignature(cert.signature, size), cert.tbs)
}

function fromBase64(value: string): Uint8Array {
  const normalized = value.replaceAll("-", "+").replaceAll("_", "/")
  const padded = normalized + "=".repeat((4 - (normalized.length % 4)) % 4)
  try {
    return Uint8Array.from(atob(padded), (c) => c.charCodeAt(0))
  } catch {
    throw new SubscriptionError("malformed")
  }
}

async function verifyChain(x5c: unknown, roots: Certificate[], at: number): Promise<Certificate> {
  if (!Array.isArray(x5c) || x5c.length < 2 || x5c.length > 4 || x5c.some((item) => typeof item !== "string")) {
    throw new SubscriptionError("untrusted_chain")
  }
  const chain = x5c.map((item) => parseCertificate(fromBase64(item as string)))
  for (const cert of chain) {
    if (at < cert.notBefore || at > cert.notAfter) throw new SubscriptionError("untrusted_chain", "certificate not valid")
  }
  for (let i = 0; i < chain.length - 1; i += 1) {
    if (!equal(chain[i].issuer, chain[i + 1].subject) || !await verifySignedBy(chain[i], chain[i + 1])) {
      throw new SubscriptionError("untrusted_chain")
    }
  }
  // The last presented certificate must be, or be signed by, a pinned root.
  const top = chain[chain.length - 1]
  let anchored = false
  for (const root of roots) {
    if (equal(root.der, top.der)) { anchored = true; break }
    if (equal(top.issuer, root.subject) && at >= root.notBefore && at <= root.notAfter && await verifySignedBy(top, root)) {
      anchored = true
      break
    }
  }
  if (!anchored) throw new SubscriptionError("untrusted_chain")
  // Anyone can mint a chain to Apple's root for other products; require the
  // StoreKit/receipt-signing marker extensions Apple puts on these two certs.
  if (!contains(chain[0].der, encodeOid(LEAF_MARKER_OID)) || !contains(chain[1].der, encodeOid(INTERMEDIATE_MARKER_OID))) {
    throw new SubscriptionError("untrusted_chain", "missing App Store marker extensions")
  }
  return chain[0]
}

function decodeJson(segment: string): Record<string, unknown> {
  try {
    const value = JSON.parse(new TextDecoder().decode(fromBase64(segment)))
    if (value && typeof value === "object" && !Array.isArray(value)) return value as Record<string, unknown>
  } catch (error) {
    if (error instanceof SubscriptionError) throw error
  }
  throw new SubscriptionError("malformed")
}

export async function verifySignedTransaction(jws: string, options: VerifyOptions): Promise<VerifiedTransaction> {
  const now = options.now ?? Date.now()
  const parts = jws.split(".")
  if (parts.length !== 3 || jws.length > 16_384) throw new SubscriptionError("malformed")
  const header = decodeJson(parts[0])
  if (header.alg !== "ES256") throw new SubscriptionError("malformed", "unsupported algorithm")
  const payload = decodeJson(parts[1])
  const signedDate = typeof payload.signedDate === "number" ? payload.signedDate : now
  if (signedDate > now + SIGNED_DATE_FUTURE_SKEW_MS) throw new SubscriptionError("malformed", "signed in the future")

  const roots = (options.trustedRootsDER ?? [APPLE_ROOT_CA_G3_DER]).map((item) => parseCertificate(fromBase64(item)))
  const leaf = await verifyChain(header.x5c, roots, Math.min(signedDate, now))
  if (leaf.curve !== "P-256") throw new SubscriptionError("untrusted_chain")
  const key = await crypto.subtle.importKey("spki", leaf.spki, { name: "ECDSA", namedCurve: "P-256" }, false, ["verify"])
  const signature = fromBase64(parts[2])
  const valid = signature.length === 64 && await crypto.subtle.verify(
    { name: "ECDSA", hash: "SHA-256" }, key, signature, new TextEncoder().encode(`${parts[0]}.${parts[1]}`),
  )
  if (!valid) throw new SubscriptionError("bad_signature")

  if (payload.bundleId !== options.bundleId) throw new SubscriptionError("wrong_bundle")
  const productId = typeof payload.productId === "string" ? payload.productId : ""
  if (!(productId in options.products) || payload.type !== "Auto-Renewable Subscription") {
    throw new SubscriptionError("unknown_product")
  }
  if (payload.revocationDate !== undefined || payload.revocationReason !== undefined) throw new SubscriptionError("revoked")
  const environment = typeof payload.environment === "string" ? payload.environment : "Production"
  const sandboxAllowed = (options.acceptSandbox ?? true) && environment === "Sandbox"
  if (environment !== "Production" && !sandboxAllowed) {
    throw new SubscriptionError("unsupported_environment")
  }
  const expiresDate = payload.expiresDate
  if (typeof expiresDate !== "number" || expiresDate + (options.graceMs ?? 0) <= now) throw new SubscriptionError("expired")
  const original = payload.originalTransactionId
  if ((typeof original !== "string" && typeof original !== "number") || !/^\d{1,20}$/.test(String(original))) {
    throw new SubscriptionError("malformed")
  }
  return { productId, originalTransactionId: String(original), expiresDate, environment, signedDate }
}
