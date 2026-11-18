// Pi 1.5.2 的 RPC 测试替身（docs/rpc-commands.md / dist/modes/rpc/rpc-mode.js）。
// 保持运行到 abort / 会话切换，方便确定性测试 busy prompt；不调用真实模型。
import { dirname, join } from "node:path"

process.stdin.setEncoding("utf8")
let buffer = ""
let isStreaming = false
let pendingMessageCount = 0
let lastUserPhoto
let model
let thinkingLevel
let sessionFile
let newSessionCount = 0
const output = (record) => process.stdout.write(`${JSON.stringify(record)}\n`)
const pendingConfirmations = new Map()

async function handle(cmd) {
  const reply = (data) => output({ type: "response", id: cmd.id, command: cmd.type, success: true, ...(data === undefined ? {} : { data }) })
  const fail = (error) => output({ type: "response", id: cmd.id, command: cmd.type, success: false, error })
  const settle = () => {
    if (isStreaming) {
      output({ type: "agent_end", messages: [] })
      output({ type: "agent_settled" })
    }
    isStreaming = false
    pendingMessageCount = 0
  }
  switch (cmd.type) {
    case "extension_ui_response":
      pendingConfirmations.get(cmd.id)?.()
      pendingConfirmations.delete(cmd.id)
      break
    case "prompt":
      if (isStreaming) {
        if (!cmd.streamingBehavior) {
          fail("Agent is already processing. Specify streamingBehavior ('steer' or 'followUp') to queue the message.")
        } else {
          pendingMessageCount++
          reply({ disposition: "queued" })
        }
      } else {
        isStreaming = true
        reply({ disposition: "started" })
        output({ type: "agent_start" })
        if (cmd.message === "synthetic photo fixture") {
          const hint = "[Image: original 2853x2007, displayed at 2000x1407. Multiply coordinates by 1.43 to map to original image.]"
          lastUserPhoto = { role: "user", content: [{ type: "text", text: `${cmd.message}\n\n${hint}` }, ...cmd.images] }
          output({ type: "message_start", message: lastUserPhoto })
          output({ type: "message_end", message: lastUserPhoto })
          settle()
        } else if (cmd.message === "synthetic privacy fixture") {
          const hidden = { type: "thinking", thinking: "fixture-private-thought", thinkingSignature: "fixture-private-signature" }
          const message = { role: "assistant", content: [hidden, { type: "text", text: "思考：<think>literal</think>" }] }
          output({ type: "message_start", message })
          for (const update of [
            { type: "thinking_start", contentIndex: 0 }, { type: "thinking_delta", delta: hidden.thinking },
            { type: "thinking_end", content: hidden.thinking },
            { type: "toolcall_start", contentIndex: 1, id: "call1", toolName: "read" },
            { type: "toolcall_delta", delta: "fixture-private-args" },
            { type: "text_delta", contentIndex: 1, delta: message.content[1].text },
          ]) output({ type: "message_update", message, assistantMessageEvent: { ...update, partial: message } })
          const result = { content: [{ type: "text", text: "tool output" }], details: { messages: [message] } }
          output({ type: "tool_execution_end", toolCallId: "call1", toolName: "read", result })
          output({ type: "message_end", message: { role: "toolResult", toolCallId: "call1", ...result } })
          output({ type: "entry_appended", entry: { type: "message", message } })
          output({ type: "message_end", message })
          output({ type: "turn_end", message, toolResults: [] })
          output({ type: "agent_end", messages: [message] })
          output({ type: "agent_settled" })
          isStreaming = false
        } else output({ type: "message_update", assistantMessageEvent: { type: "text_delta", delta: "pong" } })
      }
      break
    case "get_messages":
      reply({ messages: [lastUserPhoto ?? { role: "assistant", content: [{ type: "thinking", thinking: "fixture-private" }, { type: "text", text: "answer" }] }] })
      break
    case "get_state":
      if (Object.hasOwn(cmd, "afterSettingChangeId")) fail("Gateway-only field reached Pi")
      else reply({ isStreaming, isCompacting: false, sessionFile, pendingMessageCount, model, thinkingLevel })
      break
    case "set_model":
    case "set_thinking_level":
      await new Promise((resolve) => {
        const id = `confirm-${cmd.id}`
        pendingConfirmations.set(id, resolve)
        output({ type: "extension_ui_request", id, method: "confirm", title: "Setting change" })
      })
      if (cmd.type === "set_model") model = { provider: cmd.provider, id: cmd.modelId }
      else thinkingLevel = cmd.level
      reply()
      break
    case "switch_session":
    case "new_session": {
      if (process.env.FAKE_PI_CONFIRM_SESSION_CHANGE === "1") {
        await new Promise((resolve) => {
          const id = `confirm-${cmd.id}`
          pendingConfirmations.set(id, resolve)
          output({ type: "extension_ui_request", id, method: "confirm", title: "Session change", message: "Allow session change?" })
        })
      }
      if (process.env.FAKE_PI_FAIL_SESSION_CHANGE === "1") {
        fail("Session change failed in test extension")
        break
      }
      const cancelled = cmd.type === "switch_session"
        ? process.env.FAKE_PI_CANCEL_SWITCH === "1"
        : process.env.FAKE_PI_CANCEL_NEW === "1"
      if (!cancelled) {
        settle()
        // 默认 --no-session；打开文件后 Pi 会保持持久化模式，新路径尚未落盘。
        sessionFile = cmd.type === "switch_session" ? cmd.sessionPath
          : sessionFile ? join(dirname(sessionFile), `new-test-session-${++newSessionCount}.jsonl`) : undefined
      }
      reply({ cancelled })
      break
    }
    case "abort":
      settle()
      reply()
      break
    default:
      fail(`Unknown command: ${cmd.type}`)
  }
}

process.stdin.on("data", (chunk) => {
  buffer += chunk
  for (;;) {
    const lf = buffer.indexOf("\n")
    if (lf < 0) break
    const line = buffer.slice(0, lf).trim()
    buffer = buffer.slice(lf + 1)
    if (!line) continue
    let cmd
    try {
      cmd = JSON.parse(line)
    } catch {
      continue
    }
    // 与 Pi RPC 一致：每行独立启动异步处理，挂起的 session hook 不阻塞后续命令。
    void handle(cmd)
  }
})
