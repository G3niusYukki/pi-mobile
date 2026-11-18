// Pi Mobile relay：gateway 与 device 之间的最小路由层。
// 不解析业务内容、不落盘消息、不接触 pi 凭证。所有 payload 原字转发。
import { createServer } from "node:http"
import { randomBytes } from "node:crypto"
import { WebSocketServer, WebSocket } from "ws"

const HOST = process.env.RELAY_HOST ?? "127.0.0.1"
const PORT = Number(process.env.RELAY_PORT ?? 8789)
const GATEWAY_TOKEN = process.env.GATEWAY_TOKEN ?? ""
const PAIR_TTL_MS = 5 * 60 * 1000
const EVENT_BACKLOG = 200

if (!GATEWAY_TOKEN) {
  console.error("缺少 GATEWAY_TOKEN")
  process.exit(1)
}

const pairTokens = new Map() // token -> expiresAt
const devices = new Map() // deviceToken -> { expiresAt }
let gateway = null
let device = null
let backlog = []

function send(ws, obj) {
  if (ws?.readyState === WebSocket.OPEN) ws.send(JSON.stringify(obj))
}
function safeSend(ws, obj) {
  try {
    send(ws, obj)
  } catch {
    // 单个客户端写失败不影响路由
  }
}
function broadcastToDevice(obj) {
  safeSend(device, obj)
  if (obj.type === "event") {
    backlog.push(obj.event)
    if (backlog.length > EVENT_BACKLOG) backlog.splice(0, backlog.length - EVENT_BACKLOG)
  }
}
function broadcastToGateway(obj) {
  safeSend(gateway, obj)
}
function closeOld(ws, reason) {
  try {
    ws.close(1000, reason)
  } catch {
    // 已关闭
  }
}

const server = createServer((req, res) => {
  if (req.url === "/pi/healthz") {
    res.writeHead(200, { "content-type": "application/json" })
    res.end(JSON.stringify({ ok: true, gateway: !!gateway, device: !!device }))
    return
  }
  res.writeHead(404)
  res.end()
})

const wss = new WebSocketServer({ noServer: true, maxPayload: 12 * 1024 * 1024 })
server.on("upgrade", (req, socket, head) => {
  let path
  try {
    path = new URL(req.url ?? "/", "http://localhost").pathname
  } catch {
    socket.destroy()
    return
  }
  if (path !== "/pi/gateway" && path !== "/pi/client") {
    socket.destroy()
    return
  }
  wss.handleUpgrade(req, socket, head, (ws) => {
    ws.role = null
    wss.emit("connection", ws, req, path)
  })
})

wss.on("connection", (ws, req, path) => {
  const auth = String(req.headers.authorization ?? "")
  const bearer = auth.startsWith("Bearer ") ? auth.slice(7) : ""
  const role = path.endsWith("/gateway") ? "gateway" : "client"

  if (role === "gateway") {
    if (bearer !== GATEWAY_TOKEN) {
      ws.close(4403, "unauthorized")
      return
    }
    if (gateway && gateway !== ws) closeOld(gateway, "replaced")
    gateway = ws
    ws.role = "gateway"
    send(ws, { type: "hello", role: "gateway" })
  } else {
    ws.role = "client"
    if (bearer && devices.has(bearer) && devices.get(bearer).expiresAt > Date.now()) {
      attachDevice(ws, bearer)
    } else {
      // 未带设备令牌：等首帧 pair
      const timer = setTimeout(() => ws.close(4408, "pair timeout"), 30_000)
      ws.pairTimer = timer
    }
  }

  ws.on("pong", () => {
    ws.lastPong = Date.now()
  })
  ws.on("message", (raw) => {
    let msg
    try {
      msg = JSON.parse(String(raw))
    } catch {
      send(ws, { type: "error", message: "invalid json" })
      return
    }
    if (!msg || typeof msg !== "object") return
    if (role === "gateway") onGatewayMessage(ws, msg)
    else onClientMessage(ws, msg)
  })
  ws.on("close", () => {
    if (ws.pairTimer) clearTimeout(ws.pairTimer)
    if (gateway === ws) gateway = null
    if (device === ws) {
      device = null
      broadcastToGateway({ type: "device_status", online: false })
    }
  })
})

function attachDevice(ws, deviceToken) {
  if (ws.pairTimer) {
    clearTimeout(ws.pairTimer)
    ws.pairTimer = null
  }
  if (device && device !== ws) closeOld(device, "replaced")
  device = ws
  ws.deviceToken = deviceToken
  send(ws, { type: "paired", deviceToken })
  send(ws, { type: "status", state: gateway ? "idle" : "unknown" })
  for (const event of backlog) safeSend(ws, { type: "event", event })
  broadcastToGateway({ type: "device_status", online: true })
}

function onClientMessage(ws, msg) {
  if (msg.type === "pair") {
    const token = String(msg.token ?? "")
    const expiresAt = pairTokens.get(token)
    if (!expiresAt || expiresAt <= Date.now()) {
      send(ws, { type: "error", message: "pair token invalid or expired" })
      return
    }
    pairTokens.delete(token)
    const deviceToken = randomBytes(32).toString("hex")
    devices.set(deviceToken, { expiresAt: Date.now() + 90 * 24 * 60 * 60 * 1000 })
    attachDevice(ws, deviceToken)
    if (typeof msg.pub === "string") broadcastToGateway({ type: "pair_pub", pub: msg.pub })
    return
  }
  if (!ws.deviceToken) {
    send(ws, { type: "error", message: "not paired" })
    return
  }
  if (["rpc", "extension_ui_response", "session_list", "session_switch", "session_new", "pair_pub"].includes(msg.type)) {
    if (!gateway) {
      send(ws, { type: "error", message: "gateway offline" })
      return
    }
    broadcastToGateway(msg)
    return
  }
  send(ws, { type: "error", message: "unsupported message" })
}

function onGatewayMessage(ws, msg) {
  if (msg.type === "pair_create") {
    const token = randomBytes(16).toString("hex")
    pairTokens.set(token, Date.now() + PAIR_TTL_MS)
    send(ws, { type: "pair_token", token, expiresAt: Date.now() + PAIR_TTL_MS })
    return
  }
  if (["rpc_response", "event", "status", "session_list", "error"].includes(msg.type)) {
    broadcastToDevice(msg)
    return
  }
  if (msg.type === "device_paired") {
    send(ws, msg)
    return
  }
  send(ws, { type: "error", message: "unsupported message" })
}

const heartbeat = setInterval(() => {
  for (const ws of wss.clients) {
    if (ws.readyState !== WebSocket.OPEN) continue
    if (ws.lastPong && Date.now() - ws.lastPong > 90_000) ws.terminate()
    else ws.ping()
  }
}, 30_000)
heartbeat.unref?.()

server.listen(PORT, HOST, () => {
  console.log(`[relay] listening ${HOST}:${PORT}`)
})

export function __testServer() {
  return { server, wss }
}
