import assert from "node:assert/strict"
import test from "node:test"
import { spawn, spawnSync } from "node:child_process"
import { once } from "node:events"
import { appendFileSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs"
import { createServer } from "node:net"
import { tmpdir } from "node:os"
import { fileURLToPath } from "node:url"
import { basename, dirname, isAbsolute, join } from "node:path"
import WebSocket from "ws"
import { createCipheriv, createDecipheriv, createPublicKey, diffieHellman, generateKeyPairSync, hkdfSync, randomBytes } from "node:crypto"

const PREFIX = Buffer.from("302a300506032b656e032100", "hex")
function clientCrypto(gatewayPub) {
  const { privateKey, publicKey } = generateKeyPairSync("x25519")
  const pub = publicKey.export({ format: "der", type: "spki" }).subarray(-32).toString("base64url")
  const peer = createPublicKey({ key: Buffer.concat([PREFIX, Buffer.from(gatewayPub, "base64url")]), format: "der", type: "spki" })
  const secret = diffieHellman({ privateKey, publicKey: peer })
  const key = Buffer.from(hkdfSync("sha256", secret, "pi-mobile-e2e-v1", "pi-mobile", 32))
  return {
    pub,
    seal(value) {
      const iv = randomBytes(12)
      const c = createCipheriv("aes-256-gcm", key, iv)
      return Buffer.concat([iv, c.update(JSON.stringify(value), "utf8"), c.final(), c.getAuthTag()]).toString("base64url")
    },
    open(sealed) {
      const blob = Buffer.from(sealed, "base64url")
      const d = createDecipheriv("aes-256-gcm", key, blob.subarray(0, 12))
      d.setAuthTag(blob.subarray(blob.length - 16))
      return JSON.parse(Buffer.concat([d.update(blob.subarray(12, blob.length - 16)), d.final()]).toString("utf8"))
    },
  }
}

const root = join(dirname(fileURLToPath(import.meta.url)), "..")
const relayRoot = join(root, "../relay")
const TOKEN = "gateway-token-for-tests-123456"
const PI = join(root, "test/fake-pi.mjs")

test("网关拒绝缺少或不安全的公开配对地址", () => {
  const dir = mkdtempSync(join(tmpdir(), "pi-pair-config-"))
  try {
    for (const base of ["", "http://relay.example.com/pi/pair", "https://user@relay.example.com/pi/pair", "https://relay.example.com/pi/pair?token=demo"]) {
      const result = spawnSync(process.execPath, [join(root, "src/index.mjs")], {
        encoding: "utf8", timeout: 3000,
        env: { ...process.env, GATEWAY_TOKEN: TOKEN, PAIR_BASE: base, RELAY_URL: "ws://127.0.0.1:1/pi/gateway",
          PI_MOBILE_GATEWAY_KEY_PATH: join(dir, "key"), PI_BIN: process.execPath, PI_ARGS: "--version" },
      })
      assert.equal(result.status, 1)
      assert.match(result.stderr, /PAIR_BASE/)
      assert.equal(result.stdout, "")
    }
  } finally {
    assert.ok(isAbsolute(dir) && basename(dir).startsWith("pi-pair-config-"))
    rmSync(dir, { recursive: true, force: true })
  }
})

function waitFor(stream, predicate, timeout = 8000) {
  return new Promise((resolve, reject) => {
    let text = ""
    const cleanup = () => {
      clearTimeout(timer)
      stream.off("data", onData)
    }
    const timer = setTimeout(() => {
      cleanup()
      reject(new Error(`stdout timeout: ${text.slice(-300)}`))
    }, timeout)
    const onData = (chunk) => {
      text += String(chunk)
      if (!predicate(text)) return
      cleanup()
      resolve(text)
    }
    stream.on("data", onData)
  })
}
function waitMessage(ws, predicate, timeout = 8000) {
  return new Promise((resolve, reject) => {
    const cleanup = () => {
      clearTimeout(timer)
      ws.off("message", onMessage)
      ws.off("error", onError)
    }
    const onError = (error) => {
      cleanup()
      reject(error)
    }
    const timer = setTimeout(() => onError(new Error("message timeout")), timeout)
    const onMessage = (raw) => {
      try {
        const msg = JSON.parse(String(raw))
        if (!predicate(msg)) return
        cleanup()
        resolve(msg)
      } catch (error) {
        onError(error)
      }
    }
    ws.on("message", onMessage)
    ws.on("error", onError)
  })
}
async function unusedPort() {
  const server = createServer()
  server.listen(0, "127.0.0.1")
  await once(server, "listening")
  const port = server.address().port
  await new Promise((resolve, reject) => server.close((error) => error ? reject(error) : resolve()))
  return port
}
async function stop(child) {
  if (!child || child.exitCode !== null || child.signalCode !== null) return
  const exited = once(child, "exit")
  child.kill("SIGTERM")
  const timer = setTimeout(() => child.kill("SIGKILL"), 5000)
  try { await exited } finally { clearTimeout(timer) }
}

async function connectGateway(t, fakeEnv = {}) {
  const dir = mkdtempSync(join(tmpdir(), "pi-gateway-test-"))
  let relay
  let gateway
  let phone
  t.after(async () => {
    phone?.terminate()
    await Promise.all([stop(gateway), stop(relay)])
    assert.ok(isAbsolute(dir) && basename(dir).startsWith("pi-gateway-test-"))
    rmSync(dir, { recursive: true, force: true })
  })
  const sessionDir = join(dir, "sessions")
  mkdirSync(join(sessionDir, "--test--"), { recursive: true })
  const sessionPath = join(sessionDir, "--test--", "history.jsonl")
  const assistantText = `  ${"完整历史回答".repeat(3000)}\n  `
  writeFileSync(sessionPath, [
    { type: "session", version: 3, id: "session-fixture", cwd: dir },
    { type: "message", id: "user-id", parentId: null, message: { role: "user", content: "hello" } },
    { type: "message", id: "answer-id", parentId: "user-id", message: { role: "assistant", content: [{ type: "text", text: assistantText }] } },
    { type: "message", id: "tool-id", parentId: "answer-id", message: { role: "toolResult", toolCallId: "t1", toolName: "read", content: [{ type: "text", text: "complete output" }] } },
  ].map((entry) => JSON.stringify(entry)).join("\n"))
  const emptyPath = join(sessionDir, "--test--", "empty.jsonl")
  writeFileSync(emptyPath, JSON.stringify({ type: "session", version: 3, id: "empty", cwd: dir }))

  const port = await unusedPort()
  relay = spawn(process.execPath, [join(relayRoot, "src/index.mjs")], {
    env: { ...process.env, RELAY_HOST: "127.0.0.1", RELAY_PORT: String(port), GATEWAY_TOKEN: TOKEN },
    stdio: ["ignore", "pipe", "pipe"],
  })
  let relayLog = ""
  relay.stderr.on("data", (chunk) => (relayLog += String(chunk)))
  await waitFor(relay.stdout, (text) => text.includes("[relay] listening"))
  const gatewayOptions = {
    env: {
      ...process.env,
      RELAY_URL: `ws://127.0.0.1:${port}/pi/gateway`,
      GATEWAY_TOKEN: TOKEN,
      PI_BIN: process.execPath,
      PI_ARGS: PI,
      PI_CWD: dir,
      PI_SESSION_DIR: sessionDir,
      PI_MOBILE_GATEWAY_KEY_PATH: join(dir, "gateway.key"),
      PAIR_BASE: "https://example.test/pi/pair",
      FAKE_PI_CANCEL_SWITCH: "0",
      FAKE_PI_CANCEL_NEW: "0",
      FAKE_PI_CONFIRM_SESSION_CHANGE: "0",
      FAKE_PI_FAIL_SESSION_CHANGE: "0",
      ...fakeEnv,
    },
    stdio: ["ignore", "pipe", "pipe"],
  }
  let gatewayLog = ""
  function startGateway() {
    gateway = spawn(process.execPath, [join(root, "src/index.mjs")], gatewayOptions)
    gateway.stderr.on("data", (chunk) => (gatewayLog += String(chunk)))
  }
  startGateway()
  const pairOutput = await waitFor(gateway.stdout, (text) => text.includes("https://example.test/pi/pair#"))
  const token = pairOutput.match(/pair#([a-f0-9]{32})/)?.[1]
  const gatewayPub = pairOutput.match(/pair#[a-f0-9]{32}\.([A-Za-z0-9_-]{43})/)?.[1]
  assert.ok(gatewayPub, "配对链接应带网关公钥")
  assert.ok(token, `没有拿到配对 token：${pairOutput.slice(-300)}`)
  const phoneCrypto = clientCrypto(gatewayPub)
  phone = new WebSocket(`ws://127.0.0.1:${port}/pi/client`)
  await once(phone, "open")
  const paired = waitMessage(phone, (message) => message.type === "paired")
  const ready = waitFor(gateway.stdout, (text) => text.includes("端到端加密已启用"))
  phone.send(JSON.stringify({ type: "pair", token, pub: phoneCrypto.pub }))
  const deviceToken = (await paired).deviceToken
  assert.match(deviceToken, /^[a-f0-9]{64}$/)
  await ready

  return {
    sessionPath,
    sessionDir,
    emptyPath,
    assistantText,
    sendRpc(command) {
      phone.send(JSON.stringify({ type: "rpc", id: command.id, sealed: phoneCrypto.seal({ command }) }))
    },
    async legacyList() {
      const response = waitMessage(phone, (message) => message.type === "session_list")
      phone.send(JSON.stringify({ type: "session_list" }))
      return (await response).sessions
    },
    confirm(id) {
      phone.send(JSON.stringify({ type: "extension_ui_response", sealed: phoneCrypto.seal({ id, confirmed: true }) }))
    },
    async restartGateway() {
      await stop(gateway)
      startGateway()
    },
    waitForPairingKeyRequest() {
      return waitMessage(phone, (message) => message.type === "status" && message.needsPairingKey === true)
    },
    async reconnect() {
      const closed = once(phone, "close")
      phone.close()
      await closed
      phone = new WebSocket(`ws://127.0.0.1:${port}/pi/client`, { headers: { Authorization: `Bearer ${deviceToken}` } })
      const resumed = waitMessage(phone, (message) => message.type === "paired")
      await once(phone, "open")
      assert.equal((await resumed).deviceToken, deviceToken)
      phone.send(JSON.stringify({ type: "pair_pub", pub: phoneCrypto.pub }))
    },
    async rpc(command, envelopeId = command.id) {
      const response = waitMessage(phone, (message) => message.type === "rpc_response"
        && typeof message.sealed === "string"
        && phoneCrypto.open(message.sealed).id === (command.id ?? envelopeId))
      phone.send(JSON.stringify({ type: "rpc", id: envelopeId, sealed: phoneCrypto.seal({ command }) }))
      const envelope = await response
      assert.deepEqual(Object.keys(envelope).sort(), ["sealed", "type"], "RPC 内容应全部加密")
      return phoneCrypto.open(envelope.sealed)
    },
    collectEventsUntil(type) {
      const events = []
      return waitMessage(phone, (message) => {
        if (message.type !== "event") return false
        const event = phoneCrypto.open(message.sealed)
        events.push(event)
        return event.type === type
      }).then(() => events)
    },
    async event(type) {
      const envelope = await waitMessage(phone, (message) => message.type === "event"
        && typeof message.sealed === "string" && phoneCrypto.open(message.sealed).type === type)
      return phoneCrypto.open(envelope.sealed)
    },
    checkLogs() {
      assert.ok(!gatewayLog.includes("pi 启动失败"), gatewayLog)
      assert.equal(relayLog, "")
    },
  }
}

test("native transcript RPC projects only visible assistant content", async t => {
  const gateway = await connectGateway(t)
  const response = await gateway.rpc({ id: "msgs", type: "get_messages" })
  assert.deepEqual(response.data.messages, [{ role: "assistant", content: [{ type: "text", text: "answer" }] }])
})

test("decrypted phone events exclude Pi thinking across partials, finals and run summaries", async t => {
  const gateway = await connectGateway(t)
  const delivery = gateway.collectEventsUntil("agent_settled")
  await gateway.rpc({ id: "privacy", type: "prompt", message: "synthetic privacy fixture" })
  const events = await delivery
  assert.doesNotMatch(JSON.stringify(events), /fixture-private/)
  assert.equal(events.find(e => e.assistantMessageEvent?.type === "text_delta").assistantMessageEvent.delta, "思考：<think>literal</think>")
  assert.deepEqual(events.find(e => e.type === "tool_execution_end").result.content, [{ type: "text", text: "tool output" }])
  assert.deepEqual(events.find(e => e.type === "message_end" && e.message.role === "assistant").message.content, [{ type: "text", text: "思考：<think>literal</think>" }])
})

test("会话目录：加密返回工作目录、话题与进展，旧接口仅返回文件元数据", async (t) => {
  const gateway = await connectGateway(t)
  const file = join(dirname(gateway.sessionPath), "2026-11-18T01-00-00Z_fixture.jsonl")
  writeFileSync(file, [
    { type: "session", id: "topic", cwd: "/projects/pi-mobile" },
    { type: "message", id: "u", parentId: null, message: { role: "user", content: "修复输入框遮挡消息的问题。" } },
    { type: "message", id: "a", parentId: "u", message: { role: "assistant", content: "键盘收起后会恢复到原来的阅读位置。" } },
  ].map((row) => JSON.stringify(row)).join("\n"))
  const { success, data } = await gateway.rpc({ type: "session_catalog", id: "recent" })
  assert.equal(success, true)
  const item = data.sessions.find((entry) => entry.path === file)
  assert.equal(item.cwd, "/projects/pi-mobile")
  assert.match(item.title, /输入框/)
  assert.match(item.summary, /阅读位置/)
  const legacy = (await gateway.legacyList()).find((entry) => entry.path === file)
  assert.equal(legacy.title, basename(file, ".jsonl"))
  assert.equal(legacy.summary, undefined)
})

test("gateway：重启后在线设备沿用原配对令牌和密钥恢复加密目录", { timeout: 20000 }, async (t) => {
  const gateway = await connectGateway(t)
  const initial = await gateway.rpc({ type: "session_catalog", id: "before-restart" })
  assert.equal(initial.success, true)
  assert.ok(initial.data.sessions.some((item) => item.path === gateway.sessionPath))

  const [hint] = await Promise.all([gateway.waitForPairingKeyRequest(), gateway.restartGateway()])
  assert.equal(hint.state, "idle")
  await gateway.reconnect()
  const restored = await gateway.rpc({ type: "session_catalog", id: "after-restart" })
  assert.equal(restored.success, true)
  assert.deepEqual(restored.data.sessions, initial.data.sessions)
  gateway.checkLogs()
})

test("gateway：加密 RPC 支持忙时 steer、原生切换/新建 ACK 和带身份的历史", { timeout: 20000 }, async (t) => {
  const gateway = await connectGateway(t)
  const fresh = await gateway.rpc({ id: "initial-new", type: "new_session" })
  assert.deepEqual(fresh, { id: "initial-new", success: true, data: { cancelled: false } })
  const initialState = await gateway.rpc({ id: "initial-state", type: "get_state" })
  assert.equal(initialState.data.sessionFile, undefined, "--no-session 的新会话没有文件路径")
  const delta = gateway.event("message_update")
  const started = await gateway.rpc({ id: "prompt-1", type: "prompt", message: "ping", streamingBehavior: "steer" })
  assert.deepEqual(started, { id: "prompt-1", success: true, data: { disposition: "started" } })
  assert.equal((await delta).assistantMessageEvent.delta, "pong")

  const rejected = await gateway.rpc({ id: "prompt-without-steer", type: "prompt", message: "another message" })
  assert.equal(rejected.success, false)
  assert.equal(rejected.error, "Agent is already processing. Specify streamingBehavior ('steer' or 'followUp') to queue the message.")
  const queued = await gateway.rpc({ id: "prompt-2", type: "prompt", message: "change direction", streamingBehavior: "steer" })
  assert.deepEqual(queued, { id: "prompt-2", success: true, data: { disposition: "queued" } })
  const busy = await gateway.rpc({ id: "busy", type: "get_state" })
  assert.equal(busy.data.isStreaming, true)
  assert.equal(busy.data.pendingMessageCount, 1)

  const switched = await gateway.rpc({ id: "switch-1", type: "switch_session", sessionPath: gateway.sessionPath })
  assert.deepEqual(switched, { id: "switch-1", success: true, data: { cancelled: false } })
  const state = await gateway.rpc({ id: "state-after-switch", type: "get_state" })
  assert.equal(state.data.sessionFile, gateway.sessionPath)
  assert.equal(state.data.isStreaming, false)
  const history = await gateway.rpc({ id: "history-1", type: "session_history", sessionPath: gateway.sessionPath })
  assert.equal(history.success, true)
  assert.equal(history.data.sessionPath, gateway.sessionPath)
  assert.equal(history.data.hasEarlierMessages, false)
  assert.equal(history.data.messages.length, 3)
  assert.deepEqual(history.data.messages[0], { id: "user-id", role: "user", text: "hello" })
  assert.deepEqual(history.data.messages[1], { id: "answer-id", role: "assistant", text: gateway.assistantText })
  assert.deepEqual(history.data.messages[2], { id: "tool-id", role: "tool", toolTitle: "read", toolCallId: "t1", text: "complete output" })
  const repeated = await gateway.rpc({ id: "history-2", type: "session_history", sessionPath: gateway.sessionPath })
  assert.deepEqual(repeated.data, history.data)
  const windowPath = join(gateway.sessionDir, "window.jsonl")
  writeFileSync(windowPath, [
    { type: "session", version: 3, id: "window" },
    ...Array.from({ length: 81 }, (_, index) => ({ type: "message", id: `item-${index}`, parentId: index ? `item-${index - 1}` : null, message: { role: "user", content: `消息 ${index}` } })),
  ].map((entry) => JSON.stringify(entry)).join("\n"))
  const window = await gateway.rpc({ id: "history-window", type: "session_history", sessionPath: windowPath })
  assert.equal(window.success, true)
  assert.equal(window.data.hasEarlierMessages, true)
  assert.equal(window.data.messages.length, 80)
  assert.equal(window.data.messages[0].id, "item-1")

  const created = await gateway.rpc({ id: "new-1", type: "new_session" })
  assert.deepEqual(created, { id: "new-1", success: true, data: { cancelled: false } })
  const newState = await gateway.rpc({ id: "new-state", type: "get_state" })
  assert.equal(typeof newState.data.sessionFile, "string", "打开历史文件后，新会话保持持久化模式")
  assert.notEqual(newState.data.sessionFile, gateway.sessionPath)
  assert.equal(dirname(newState.data.sessionFile), dirname(gateway.sessionPath))
  assert.equal(newState.data.isStreaming, false)
  gateway.checkLogs()
})

test("gateway：加密历史锚点跨过 80 条后台新增，分支变更不保留旧锚点", { timeout: 20000 }, async (t) => {
  const gateway = await connectGateway(t)
  const initial = await gateway.rpc({ id: "initial-history", type: "session_history", sessionPath: gateway.sessionPath })
  const anchor = initial.data.messages.at(-1)
  assert.equal(anchor.id, "tool-id")
  appendFileSync(gateway.sessionPath, Array.from({ length: 120 }, (_, index) => `\n${JSON.stringify({
    type: "message", id: `new-${index}`, parentId: index ? `new-${index - 1}` : anchor.id,
    message: { role: "assistant", content: `后台新增 ${index}` },
  })}`).join(""))
  const window = await gateway.rpc({ id: "window-history", type: "session_history", sessionPath: gateway.sessionPath })
  assert.equal(window.data.messages.length, 80)
  assert.equal(window.data.messages[0].id, "new-40")
  const expanded = await gateway.rpc({ id: "expanded-history", type: "session_history", sessionPath: gateway.sessionPath, anchorId: anchor.id })
  assert.equal(expanded.success, true)
  assert.equal(expanded.data.messages.length, 121)
  assert.deepEqual(expanded.data.messages[0], anchor)
  assert.equal(expanded.data.messages.at(-1).id, "new-119")
  assert.equal(expanded.data.hasEarlierMessages, true)
  appendFileSync(gateway.sessionPath, `\n${JSON.stringify({ type: "message", id: "new-branch", parentId: null, message: { role: "user", content: "另一个分支" } })}`)
  const branched = await gateway.rpc({ id: "branch-history", type: "session_history", sessionPath: gateway.sessionPath, anchorId: anchor.id })
  assert.deepEqual(branched.data.messages, [{ id: "new-branch", role: "user", text: "另一个分支" }])
  assert.equal(branched.data.hasEarlierMessages, false)
  gateway.checkLogs()
})

for (const change of [
  { type: "set_model", provider: "fixture", modelId: "new-model" },
  { type: "set_thinking_level", level: "high" },
]) {
  test(`gateway：setting barrier waits for ${change.type} across reconnect`, { timeout: 20000 }, async (t) => {
    const gateway = await connectGateway(t)
    const confirmation = gateway.event("extension_ui_request")
    gateway.sendRpc({ id: "mutation", ...change })
    const hook = await confirmation
    await gateway.reconnect()
    let received = false
    const snapshot = gateway.rpc({ id: "recover", type: "get_state", afterSettingChangeId: "mutation" }).then((value) => {
      received = true
      return value
    })
    const probe = await gateway.rpc({ id: "probe", type: "barrier_probe" })
    assert.equal(probe.error, "Unknown command: barrier_probe")
    assert.equal(received, false, "state must wait for pending native mutation")
    gateway.confirm(hook.id)
    const state = await snapshot
    assert.equal(state.success, true)
    assert.equal(state.data.settingBarrierId, "mutation")
    assert.equal(state.data.sessionBarrier, true)
    assert.equal(state.data.sessionBarrierId, undefined)
    if (change.type === "set_model") assert.deepEqual(state.data.model, { provider: change.provider, id: change.modelId })
    else assert.equal(state.data.thinkingLevel, change.level)
    gateway.checkLogs()
  })
}

for (const scenario of [
  { name: "重连后的切换", type: "switch_session", reconnect: true, changed: true },
  { name: "新建", type: "new_session", changed: true },
  { name: "被取消的切换", type: "switch_session", env: { FAKE_PI_CANCEL_SWITCH: "1" }, changed: false },
  { name: "失败的切换", type: "switch_session", env: { FAKE_PI_FAIL_SESSION_CHANGE: "1" }, changed: false },
]) {
  test(`gateway：状态屏障等待${scenario.name}原生响应，扩展确认仍可通过`, { timeout: 20000 }, async (t) => {
    const gateway = await connectGateway(t, { FAKE_PI_CONFIRM_SESSION_CHANGE: "1", ...scenario.env })
    await gateway.rpc({ id: "start-busy", type: "prompt", message: "ping", streamingBehavior: "steer" })
    const confirmation = gateway.event("extension_ui_request")
    // 不保留原操作回调，模拟手机已将 ACK 标为未知；只读状态恢复不能重放操作。
    gateway.sendRpc({ id: "pending-change", type: scenario.type, sessionPath: gateway.sessionPath })
    const hook = await confirmation
    if (scenario.reconnect) await gateway.reconnect()
    let snapshotReceived = false
    const snapshot = gateway.rpc({ id: "recovery-state", type: "get_state", afterSessionChangeId: "pending-change" }).then((value) => {
      snapshotReceived = true
      return value
    })
    // 此独立命令必须可越过挂起的 hook；如果 get_state 被提前发给 Pi，它会先于 probe 回应。
    const probe = await gateway.rpc({ id: "probe", type: "barrier_probe" })
    assert.equal(probe.error, "Unknown command: barrier_probe")
    assert.equal(snapshotReceived, false, "原生会话变更尚未返回，不能提前读取状态")
    gateway.confirm(hook.id)
    const state = await snapshot
    assert.equal(state.success, true)
    assert.equal(state.data.sessionBarrier, true)
    assert.equal(state.data.sessionBarrierId, "pending-change")
    assert.equal(state.data.isStreaming, !scenario.changed)
    assert.equal(state.data.sessionFile, scenario.changed && scenario.type === "switch_session" ? gateway.sessionPath : undefined)
    const notReceived = await gateway.rpc({ id: "undelivered-state", type: "get_state", afterSessionChangeId: "never-delivered" })
    assert.equal(notReceived.data.sessionBarrier, true)
    assert.equal(notReceived.data.sessionBarrierId, "never-delivered")
    assert.equal(notReceived.data.sessionFile, state.data.sessionFile, "未到达网关的原操作恢复为实际状态，不推断切换成功")
    gateway.checkLogs()
  })
}

test("gateway：历史加载错误返回加密失败，不能伪装为空会话", { timeout: 20000 }, async (t) => {
  const gateway = await connectGateway(t)
  const invalidPath = join(gateway.sessionDir, "invalid.jsonl")
  writeFileSync(invalidPath, "invalid json\n{unfinished")
  const paths = [undefined, "", join(gateway.sessionDir, "missing.jsonl"), invalidPath, join(gateway.sessionDir, "..", "outside.jsonl")]
  for (const [index, sessionPath] of paths.entries()) {
    const response = await gateway.rpc({ id: `bad-history-${index}`, type: "session_history", sessionPath })
    assert.equal(response.success, false, `无效路径不可返回成功：${sessionPath}`)
    assert.equal(typeof response.error, "string")
    assert.ok(response.error.length > 0)
    assert.equal(response.data, undefined)
  }
  const empty = await gateway.rpc({ type: "session_history", sessionPath: gateway.emptyPath }, "empty-envelope-id")
  assert.deepEqual(empty, { id: "empty-envelope-id", success: true, data: { sessionPath: gateway.emptyPath, messages: [], hasEarlierMessages: false } })
  const unknown = await gateway.rpc({ id: "unknown", type: "nonexistent_command" })
  assert.equal(unknown.success, false)
  assert.equal(unknown.error, "Unknown command: nonexistent_command")
})

test("gateway：原生会话操作被扩展取消时保留 cancelled ACK", { timeout: 20000 }, async (t) => {
  const gateway = await connectGateway(t, { FAKE_PI_CANCEL_SWITCH: "1", FAKE_PI_CANCEL_NEW: "1" })
  for (const type of ["switch_session", "new_session"]) {
    const response = await gateway.rpc({ id: type, type, sessionPath: gateway.sessionPath })
    assert.deepEqual(response, { id: type, success: true, data: { cancelled: true } })
  }
})
