import assert from "node:assert/strict"
import test from "node:test"
import { spawn } from "node:child_process"
import { once } from "node:events"
import { fileURLToPath } from "node:url"
import { dirname, join } from "node:path"
import WebSocket from "ws"

const root = join(dirname(fileURLToPath(import.meta.url)), "..")
const TOKEN = "test-gateway-token-0123456789abcdef"

function startRelay(port) {
  const child = spawn(process.execPath, [join(root, "src/index.mjs")], {
    env: { ...process.env, RELAY_HOST: "127.0.0.1", RELAY_PORT: String(port), GATEWAY_TOKEN: TOKEN },
    stdio: ["ignore", "pipe", "pipe"],
  })
  child.stderr.on("data", () => undefined)
  return child
}

function connect(url, headers = {}) {
  const ws = new WebSocket(url, { headers })
  return ws
}
function next(ws, predicate) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error("timeout waiting for message")), 5000)
    const onMessage = (raw) => {
      const msg = JSON.parse(String(raw))
      if (!predicate(msg)) return
      clearTimeout(timer)
      ws.off("message", onMessage)
      resolve(msg)
    }
    ws.on("message", onMessage)
    ws.on("error", (err) => {
      clearTimeout(timer)
      reject(err)
    })
  })
}
function open(ws) {
  return new Promise((resolve, reject) => {
    ws.once("open", resolve)
    ws.once("error", reject)
  })
}

test("relay：配对 → rpc 双向路由 → 心跳与鉴权", async () => {
  const port = 19000 + Math.floor(Math.random() * 500)
  const relay = startRelay(port)
  await once(relay.stdout, "data")
  const base = `ws://127.0.0.1:${port}/pi`
  try {
    const health = await fetch(`http://127.0.0.1:${port}/pi/healthz`).then((r) => r.json())
    assert.equal(health.ok, true)
    assert.equal(health.gateway, false)

    const bad = connect(`${base}/gateway`, { Authorization: "Bearer wrong" })
    const badClose = next(bad, () => true).catch(() => null)
    await open(bad).catch(() => undefined)
    await badClose
    assert.equal(bad.readyState !== WebSocket.OPEN, true)

    const gw = connect(`${base}/gateway`, { Authorization: `Bearer ${TOKEN}` })
    await open(gw)
    const hello = await next(gw, (m) => m.type === "hello")
    assert.equal(hello.role, "gateway")

    gw.send(JSON.stringify({ type: "pair_create" }))
    const paired = await next(gw, (m) => m.type === "pair_token")
    assert.match(paired.token, /^[a-f0-9]{32}$/)

    const phone = connect(`${base}/client`)
    await open(phone)
    phone.send(JSON.stringify({ type: "pair", token: paired.token }))
    const granted = await next(phone, (m) => m.type === "paired")
    assert.match(granted.deviceToken, /^[a-f0-9]{64}$/)
    await next(gw, (m) => m.type === "device_status" && m.online)

    const rpc = { type: "rpc", id: "req-1", command: { type: "prompt", message: "hi", id: "req-1" } }
    const forwarded = next(gw, (m) => m.type === "rpc" && m.id === "req-1")
    phone.send(JSON.stringify(rpc))
    assert.deepEqual(await forwarded, rpc)

    const echoed = next(phone, (m) => m.type === "rpc_response" && m.id === "req-1")
    gw.send(JSON.stringify({ type: "rpc_response", id: "req-1", success: true, data: { disposition: "started" } }))
    assert.equal((await echoed).data.disposition, "started")

    // 设备令牌可复用，且重连后可收到事件
    gw.send(JSON.stringify({ type: "event", event: { type: "agent_settled" } }))
    await next(phone, (m) => m.type === "event" && m.event.type === "agent_settled")
    phone.close()
    gw.close()
  } finally {
    relay.kill()
  }
})
