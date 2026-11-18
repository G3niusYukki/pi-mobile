import assert from "node:assert/strict"
import test from "node:test"
import { createPublicKey, diffieHellman, generateKeyPairSync, hkdfSync, randomBytes, createCipheriv, createDecipheriv } from "node:crypto"
import { mkdtempSync, rmSync } from "node:fs"
import { tmpdir } from "node:os"
import { basename, isAbsolute, join } from "node:path"

const PREFIX = Buffer.from("302a300506032b656e032100", "hex")

function clientSide(gatewayPub) {
  const { privateKey, publicKey } = generateKeyPairSync("x25519")
  const pub = publicKey.export({ format: "der", type: "spki" }).subarray(-32).toString("base64url")
  const raw = Buffer.from(gatewayPub, "base64url")
  const peer = createPublicKey({ key: Buffer.concat([PREFIX, raw]), format: "der", type: "spki" })
  const secret = diffieHellman({ privateKey, publicKey: peer })
  const key = Buffer.from(hkdfSync("sha256", secret, "pi-mobile-e2e-v1", "pi-mobile", 32))
  return {
    pub,
    open(sealed) {
      const blob = Buffer.from(sealed, "base64url")
      const d = createDecipheriv("aes-256-gcm", key, blob.subarray(0, 12))
      d.setAuthTag(blob.subarray(blob.length - 16))
      return JSON.parse(Buffer.concat([d.update(blob.subarray(12, blob.length - 16)), d.final()]).toString("utf8"))
    },
    seal(value) {
      const iv = randomBytes(12)
      const c = createCipheriv("aes-256-gcm", key, iv)
      return Buffer.concat([iv, c.update(JSON.stringify(value), "utf8"), c.final(), c.getAuthTag()]).toString("base64url")
    },
  }
}

test("E2E：X25519 + HKDF + AES-GCM 双向加解密", async (t) => {
  const dir = mkdtempSync(join(tmpdir(), "pi-crypto-test-"))
  const previousKeyPath = process.env.PI_MOBILE_GATEWAY_KEY_PATH
  process.env.PI_MOBILE_GATEWAY_KEY_PATH = join(dir, "gateway.key")
  t.after(() => {
    if (previousKeyPath === undefined) delete process.env.PI_MOBILE_GATEWAY_KEY_PATH
    else process.env.PI_MOBILE_GATEWAY_KEY_PATH = previousKeyPath
    assert.ok(isAbsolute(dir) && basename(dir).startsWith("pi-crypto-test-"))
    rmSync(dir, { recursive: true, force: true })
  })
  const { agree, gatewayPublicKey, hasSessionKey, open, seal } = await import("../src/crypto.mjs")
  const client = clientSide(gatewayPublicKey)
  assert.equal(hasSessionKey(), false)
  assert.equal(agree(client.pub), true)
  assert.equal(hasSessionKey(), true)

  const fromGateway = seal({ type: "event", delta: "你好 relay 看不到我" })
  assert.deepEqual(client.open(fromGateway), { type: "event", delta: "你好 relay 看不到我" })

  const fromClient = client.seal({ type: "prompt", message: "secret" })
  assert.deepEqual(open(fromClient), { type: "prompt", message: "secret" })

  assert.equal(open(client.seal({ type: "tampered" }).slice(0, -4) + "AAAA"), null)
})
