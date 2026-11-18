import {
    createCipheriv,
    createDecipheriv,
    createPublicKey,
    createPrivateKey,
    diffieHellman,
    generateKeyPairSync,
    hkdfSync,
    randomBytes,
} from "node:crypto"
import { chmodSync, existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs"
import { homedir } from "node:os"
import { dirname, join } from "node:path"

// relay 只能看到 sealed 密文；密钥由配对阶段的 X25519 交换得出。
const SPKI_PREFIX = Buffer.from("302a300506032b656e032100", "hex")
const PKCS8_PREFIX = Buffer.from("302e020100300506032b656e04220420", "hex")
const SALT = "pi-mobile-e2e-v1"
const KEY_PATH = process.env.PI_MOBILE_GATEWAY_KEY_PATH
    ?? join(homedir(), ".pi", "agent", "pi-mobile-gateway.key")

/// 网关重启后保持同一对 X25519 密钥，已配对手机无需重新扫码。
function loadOrCreatePrivateKey() {
    try {
        if (existsSync(KEY_PATH)) {
            const raw = Buffer.from(readFileSync(KEY_PATH, "utf8").trim(), "base64url")
            if (raw.length === 32) {
                return createPrivateKey({
                    key: Buffer.concat([PKCS8_PREFIX, raw]),
                    format: "der",
                    type: "pkcs8",
                })
            }
        }
    } catch {
        // 文件损坏时重新生成
    }

    const { privateKey } = generateKeyPairSync("x25519")
    const raw = privateKey.export({ format: "der", type: "pkcs8" }).subarray(-32)
    try {
        mkdirSync(dirname(KEY_PATH), { recursive: true })
        writeFileSync(KEY_PATH, raw.toString("base64url"), { mode: 0o600 })
        chmodSync(KEY_PATH, 0o600)
    } catch {
        // 只读环境下仍可运行，只是重启后密钥会变化
    }
    return privateKey
}

const privateKey = loadOrCreatePrivateKey()

export const gatewayPublicKey = createPublicKey(privateKey)
    .export({ format: "der", type: "spki" })
    .subarray(-32)
    .toString("base64url")

let sessionKey = null

export function agree(pubBase64url) {
    try {
        const raw = Buffer.from(pubBase64url, "base64url")
        if (raw.length !== 32) return false
        const peer = createPublicKey({ key: Buffer.concat([SPKI_PREFIX, raw]), format: "der", type: "spki" })
        const secret = diffieHellman({ privateKey, publicKey: peer })
        sessionKey = Buffer.from(hkdfSync("sha256", secret, SALT, "pi-mobile", 32))
        return true
    } catch {
        return false
    }
}

export function hasSessionKey() {
    return sessionKey !== null
}

export function seal(value) {
    if (!sessionKey) return null
    const iv = randomBytes(12)
    const cipher = createCipheriv("aes-256-gcm", sessionKey, iv)
    const encrypted = Buffer.concat([cipher.update(JSON.stringify(value), "utf8"), cipher.final()])
    return Buffer.concat([iv, encrypted, cipher.getAuthTag()]).toString("base64url")
}

export function open(sealed) {
    if (!sessionKey || typeof sealed !== "string") return null
    try {
        const blob = Buffer.from(sealed, "base64url")
        const iv = blob.subarray(0, 12)
        const tag = blob.subarray(blob.length - 16)
        const body = blob.subarray(12, blob.length - 16)
        const decipher = createDecipheriv("aes-256-gcm", sessionKey, iv)
        decipher.setAuthTag(tag)
        return JSON.parse(Buffer.concat([decipher.update(body), decipher.final()]).toString("utf8"))
    } catch {
        return null
    }
}
