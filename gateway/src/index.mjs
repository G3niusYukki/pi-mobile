// Mac 网关：唯一的 pi 进程宿主。relay 只看到包装后的 JSON，永远拿不到本机密钥与文件。
import { spawn } from "node:child_process"
import { readFileSync } from "node:fs"
import { homedir } from "node:os"
import { basename, join } from "node:path"
import { env } from "node:process"
import QRCode from "qrcode"
import WebSocket from "ws"
import { agree, gatewayPublicKey, hasSessionKey, open, seal } from "./crypto.mjs"
import { MAX_ATTACHMENT_BYTES, projectUserContent, readSessionHistoryStrict } from "./history.mjs"
import { listSessionCatalog } from "./session-catalog.mjs"

// 令牌从同目录 .env 读取，不进命令行历史。
try {
  for (const line of readFileSync(new URL("../.env", import.meta.url), "utf8").split(/\r?\n/)) {
    const match = /^([A-Z_][A-Z0-9_]*)=(.*)$/.exec(line.trim())
    if (match && env[match[1]] === undefined) env[match[1]] = match[2]
  }
} catch {
  // 没有 .env 时沿用环境变量
}

const RELAY_URL = env.RELAY_URL ?? "ws://127.0.0.1:8789/pi/gateway"
const TOKEN = env.GATEWAY_TOKEN ?? ""
const PI_BIN = env.PI_BIN ?? "pi"
const PI_CWD = env.PI_CWD ?? process.cwd()
const PI_ARGS = (env.PI_ARGS ?? "--mode rpc").split(/\s+/).filter(Boolean)
const PAIR_BASE = env.PAIR_BASE ?? ""
const SESSION_DIR = env.PI_SESSION_DIR ?? join(homedir(), ".pi/agent/sessions")

if (!TOKEN) {
  console.error("缺少 GATEWAY_TOKEN")
  process.exit(1)
}

// The phone derives its WSS origin from this URL. Never fall back to another operator's relay.
let pairURL
try {
  pairURL = new URL(PAIR_BASE)
} catch { /* report one actionable configuration error below */ }
if (!pairURL || pairURL.protocol !== "https:" || pairURL.pathname !== "/pi/pair" ||
    pairURL.username || pairURL.password || pairURL.search || pairURL.hash) {
  console.error("请将 PAIR_BASE 设置为中继的公开 HTTPS 配对地址，例如 https://relay.example.com/pi/pair")
  process.exit(1)
}

let child = null
let relay = null
let stdoutBuffer = Buffer.alloc(0)
let shuttingDown = false
let serial = 0
const nativeRequests = new Map()
const pendingStateChanges = new Set()

function toRelay(obj) {
  if (relay?.readyState === WebSocket.OPEN) relay.send(JSON.stringify(obj))
}
// Pi repeats the whole assistant message in partials, finals and run summaries.
// Project protocol fields at the phone boundary; literal markup inside text is ordinary text.
function phoneContent(content) {
  if (typeof content === "string") return content
  if (!Array.isArray(content)) return []
  return content.filter(block => block?.type === "text" && typeof block.text === "string").map(({ text }) => ({ type: "text", text }))
}
function phoneMessage(message) {
  if (!message) return undefined
  const { role, toolCallId, toolName } = message
  if (role === "user") {
    const { text, attachments } = projectUserContent(message.content)
    if (attachments.length) return { role, content: [...(text ? [{ type: "text", text }] : []), ...attachments] }
  }
  return { role, toolCallId, toolName, content: phoneContent(message.content) }
}
function phoneEvent(event) {
  const { type, sessionPath } = event
  if (type === "message_update") {
    const update = event.assistantMessageEvent
    // Only the transition crosses the wire. The partial snapshot and token deltas stay on the Mac.
    if (update?.type === "thinking_start") return { type: "run_phase", phase: "thinking", sessionPath }
    if (update?.type === "toolcall_start") return { type: "run_phase", phase: "preparing_tool", sessionPath }
    if (!["text_start", "text_delta", "text_end"].includes(update?.type)) return null
    return { type, sessionPath, message: phoneMessage(event.message ?? update.partial),
      assistantMessageEvent: { type: update.type, delta: update.type === "text_delta" ? update.delta : undefined } }
  }
  if (type === "message_start" || type === "message_end") return { type, sessionPath, message: phoneMessage(event.message) }
  // These lifecycle signals need no copy of the transcript on the phone.
  if (["turn_start", "turn_end", "agent_start", "agent_end", "agent_settled"].includes(type)) return { type, sessionPath }
  if (type === "extension_ui_request") return event
  if (["tool_execution_start", "tool_execution_update", "tool_execution_end"].includes(type)) {
    const { toolCallId, toolName, isError, durationMs, partialResult, result } = event
    return { type, sessionPath, toolCallId, toolName, isError, durationMs,
      partialResult: partialResult && { content: phoneContent(partialResult.content) },
      result: result && { content: phoneContent(result.content) } }
  }
  // Session-internal events (including entry_appended) can carry entire raw records.
  return null
}
function respond(record) {
  const tracked = nativeRequests.get(record.id)
  const request = tracked?.type === record.command ? tracked : undefined
  let data = record.data
  if (record.command === "get_messages" && Array.isArray(data?.messages)) {
    data = { ...data, messages: data.messages.map(phoneMessage) }
  }
  if (request) {
    nativeRequests.delete(record.id)
    if (request.done) {
      pendingStateChanges.delete(request.done)
      request.resolve()
    }
    if (request.type === "get_state" && record.success === true && data && typeof data === "object") {
      data = { ...data, sessionBarrier: true }
      if (typeof request.afterSessionChangeId === "string") data.sessionBarrierId = request.afterSessionChangeId
      if (typeof request.afterSettingChangeId === "string") data.settingBarrierId = request.afterSettingChangeId
    }
  }
  const sealed = seal({ id: request ? request.id : record.id ?? null, success: record.success, data, error: record.error })
  toRelay({ type: "rpc_response", sealed })
}
function failNativeRequests(error) {
  for (const [id, request] of nativeRequests) {
    respond({ type: "response", id, command: request.type, success: false, error })
  }
}
function forwardToPi(obj) {
  const isStateChange = ["switch_session", "new_session", "set_model", "set_thinking_level"].includes(obj?.type)
  if (!isStateChange && obj?.type !== "get_state") {
    if (child?.stdin?.writable) child.stdin.write(`${JSON.stringify(obj)}\n`)
    return
  }
  // 独立的原生 ID 避免客户端 ID 缺失/复用误解锁屏障；响应还原客户端 ID。
  const id = `gateway-native-${++serial}`
  const { afterSessionChangeId, afterSettingChangeId, ...command } = obj
  const request = { id: obj.id ?? null, type: obj.type, afterSessionChangeId, afterSettingChangeId }
  if (isStateChange) {
    request.done = new Promise((resolve) => { request.resolve = resolve })
    pendingStateChanges.add(request.done)
  }
  // 必须在写 stdin 前同步登记，后续 get_state 才能看到所有已接收的会话和设置变更。
  nativeRequests.set(id, request)
  if (!child?.stdin?.writable || child.exitCode !== null || child.signalCode !== null) {
    respond({ type: "response", id, command: obj.type, success: false, error: "Pi process is not available" })
    return
  }
  child.stdin.write(`${JSON.stringify({ ...command, id })}\n`, (error) => {
    if (error && nativeRequests.has(id)) {
      respond({ type: "response", id, command: obj.type, success: false, error: error.message })
    }
  })
}
async function stateAfterChanges(command) {
  // Pi 会并发处理 JSONL 命令；仅状态查询等待，扩展 UI 回复仍可解除原生 hook。
  while (pendingStateChanges.size) await Promise.all([...pendingStateChanges])
  forwardToPi(command)
}
function toPi(obj) {
  if (obj?.type === "get_state") void stateAfterChanges(obj)
  else forwardToPi(obj)
}

function startPi() {
  child = spawn(PI_BIN, PI_ARGS, {
    cwd: PI_CWD,
    stdio: ["pipe", "pipe", "pipe"],
    env: { ...process.env, PI_MODE: "rpc" },
  })
  child.on("error", (error) => {
    failNativeRequests(error.message)
    console.error("[gateway] pi 启动失败：", error.message)
    toRelay({ type: "status", state: "unknown", error: error.message })
  })
  child.stdin.on("error", (error) => failNativeRequests(error.message))
  child.stderr.on("data", (chunk) => {
    // 诊断只进本地 stderr，不转发给手机
    process.stderr.write(`[pi] ${String(chunk).trimEnd()}\n`)
  })
  child.stdout.on("data", (chunk) => {
    stdoutBuffer = Buffer.concat([stdoutBuffer, chunk])
    for (;;) {
      const lf = stdoutBuffer.indexOf(0x0a)
      if (lf < 0) break
      const line = stdoutBuffer.subarray(0, lf).toString("utf8").replace(/\r$/, "")
      stdoutBuffer = stdoutBuffer.subarray(lf + 1)
      if (!line.trim()) continue
      let record
      try {
        record = JSON.parse(line)
      } catch {
        process.stderr.write(`[pi] 非 JSON stdout: ${line.slice(0, 200)}\n`)
        continue
      }
      if (!record || typeof record !== "object") continue
      if (record.type === "response") {
        respond(record)
      } else {
        const event = phoneEvent(record)
        if (!event) continue
        const sealed = seal(event)
        toRelay({ type: "event", sealed })
      }
    }
  })
  child.on("exit", (code) => {
    failNativeRequests(`Pi process exited (${code})`)
    if (!shuttingDown) {
      console.error(`[gateway] pi 退出（${code}），网关停止`)
      toRelay({ type: "status", state: "unknown" })
      relay?.close()
    }
  })
  console.log(`[gateway] pi 已启动：${PI_BIN} ${PI_ARGS.join(" ")} @ ${PI_CWD}`)
}

function connect() {
  relay = new WebSocket(RELAY_URL, { headers: { Authorization: `Bearer ${TOKEN}` } })
  relay.on("open", () => {
    console.log(`[gateway] 已连 relay ${RELAY_URL}`)
    relay.send(JSON.stringify({ type: "pair_create" }))
    // 网关重启时，手机可能仍连着 relay，需要它重发配对公钥。
    if (!hasSessionKey()) toRelay({ type: "status", state: "idle", needsPairingKey: true })
  })
  relay.on("message", async (raw) => {
    let msg
    try {
      msg = JSON.parse(String(raw))
    } catch {
      return
    }
    if (msg.type === "pair_token") {
      const url = `${PAIR_BASE}#${msg.token}.${gatewayPublicKey}`
      const qr = await QRCode.toString(url, { type: "terminal", small: true }).catch(() => "")
      console.log("\n[iPhone] 扫码配对（5 分钟有效）：")
      console.log(qr)
      console.log(url, "\n")
      return
    }
    if (msg.type === "pair_pub") {
      if (!agree(msg.pub)) {
        toRelay({ type: "error", message: "端到端密钥协商失败，请重新配对" })
        return
      }
      console.log("[gateway] 端到端加密已启用")
      return
    }
    if (msg.type === "rpc" || msg.type === "extension_ui_response") {
      if (!hasSessionKey()) {
        toRelay({ type: "error", message: "尚未完成加密配对" })
        return
      }
      const payload = open(msg.sealed)
      if (!payload) return
      msg = { ...msg, ...payload }
      if (msg.type === "rpc" && msg.command?.type === "session_catalog") {
        const id = msg.command.id ?? msg.id ?? null
        try {
          const sessions = await listSessionCatalog(SESSION_DIR)
          toRelay({ type: "rpc_response", sealed: seal({ id, success: true, data: { sessions } }) })
          console.log(`[gateway] 已处理加密目录请求（${sessions.length} 个会话）`)
        } catch {
          toRelay({ type: "rpc_response", sealed: seal({ id, success: false, error: "读取会话目录失败" }) })
        }
        return
      }
      if (msg.type === "rpc" && msg.command?.type === "session_history") {
        const command = msg.command
        const id = command.id ?? msg.id ?? null
        let response
        try {
          response = { id, success: true, data: readSessionHistoryStrict(command.sessionPath, SESSION_DIR, { anchorId: command.anchorId }) }
        } catch (error) {
          response = { id, success: false, error: error instanceof Error ? error.message : String(error) }
        }
        toRelay({ type: "rpc_response", sealed: seal(response) })
        return
      }
      if (msg.type === "rpc") {
        const images = msg.command?.images
        if (Array.isArray(images) && images.some((image) => Buffer.byteLength(String(image.data ?? ""), "base64") > MAX_ATTACHMENT_BYTES)) {
          toRelay({ type: "error", message: `单张图片超过 ${Math.round(MAX_ATTACHMENT_BYTES / 1024 / 1024)} MiB，请在手机上压缩后重试` })
          return
        }
      }
      toPi(msg.type === "rpc" ? msg.command : msg)
      return
    }
    if (msg.type === "session_list") {
      // Pre-catalog clients can read file metadata only. Excerpts belong in sealed RPC.
      const entries = await listSessionCatalog(SESSION_DIR).catch(() => [])
      const sessions = entries.map(({ path, cwd, mtime }) => ({ path, cwd, mtime, title: basename(path, ".jsonl") }))
      toRelay({ type: "session_list", sessions })
      return
    }
    if (msg.type === "session_switch" || msg.type === "session_new") {
      serial += 1
      const command = msg.type === "session_new"
        ? { type: "new_session", id: `s${serial}` }
        : { type: "switch_session", id: `s${serial}`, sessionPath: msg.sessionPath }
      toPi(command)
      return
    }
    if (msg.type === "device_status") {
      console.log(`[gateway] 手机${msg.online ? "已连接" : "已断开"}`)
      return
    }
    if (msg.type === "hello") return
    if (msg.type === "error") {
      console.error(`[relay] ${msg.message}`)
      return
    }
  })
  relay.on("close", (code) => {
    console.error(`[gateway] relay 断开 (${code})，3 秒后重连`)
    if (!shuttingDown) setTimeout(connect, 3000).unref?.()
  })
  relay.on("error", (error) => console.error(`[gateway] WSS 错误：${error.message}`))
}

function shutdown() {
  if (shuttingDown) return
  shuttingDown = true
  try {
    child?.stdin?.end()
  } catch {
    // 忽略
  }
  try {
    relay?.close()
  } catch {
    // 忽略
  }
  setTimeout(() => {
    child?.kill("SIGTERM")
    process.exit(0)
  }, 3000).unref?.()
}
process.on("SIGINT", shutdown)
process.on("SIGTERM", shutdown)

startPi()
connect()
