import assert from "node:assert/strict"
import test from "node:test"
import { appendFileSync, mkdirSync, mkdtempSync, rmSync, symlinkSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { basename, isAbsolute, join } from "node:path"
import { readSessionHistory } from "../src/history.mjs"
import * as history from "../src/history.mjs"

function fixture(t, entries = [{ type: "session", version: 3, id: "test-session", cwd: "/tmp" }]) {
    const dir = mkdtempSync(join(tmpdir(), "pi-history-"))
    t.after(() => {
        assert.ok(isAbsolute(dir) && basename(dir).startsWith("pi-history-"))
        rmSync(dir, { recursive: true, force: true })
    })
    const file = join(dir, "session.jsonl")
    writeFileSync(file, entries.map((entry) => typeof entry === "string" ? entry : JSON.stringify(entry)).join("\n"))
    return { dir, file }
}

test("会话历史：解析 user / assistant / toolResult，并拒绝越界路径", (t) => {
    const { dir, file } = fixture(t)
    const lines = [
        { type: "session", id: "abc", cwd: "/tmp" },
        { type: "model_change", provider: "magpie", modelId: "x" },
        {
            type: "message",
            message: { role: "user", content: [{ type: "text", text: "你好" }] },
        },
        {
            type: "message",
            message: {
                role: "assistant",
                content: [
                    { type: "thinking", thinking: "内部思考" },
                    { type: "text", text: "收到" },
                ],
            },
        },
        {
            type: "message",
            message: {
                role: "toolResult",
                toolName: "bash",
                content: [{ type: "text", text: "ok" }],
            },
        },
    ]
    writeFileSync(file, lines.map((line) => JSON.stringify(line)).join("\n"))

    const messages = readSessionHistory(file, dir)
    assert.deepEqual(messages.map((item) => item.role), ["user", "assistant", "tool"])
    assert.equal(messages[0].text, "你好")
    assert.equal(messages[1].text, "收到")
    assert.equal(messages[2].toolTitle, "bash")
    assert.equal(readSessionHistory(join(dir, "..", "etc", "passwd"), dir).length, 0)
    assert.equal(readSessionHistory("/etc/passwd", dir).length, 0)

})

test("会话历史：保留消息 ID 与完整长正文及空白格式", (t) => {
    const assistantText = `  # 完整回答\n${"详细说明".repeat(4000)}\n  `
    const toolText = `    ${"完整输出".repeat(1000)}\n`
    const { dir, file } = fixture(t, [
        { type: "session", version: 3, id: "session" },
        { type: "message", id: "user-id", parentId: null, message: { role: "user", content: "问题" } },
        { type: "message", id: "answer-id", parentId: "user-id", message: { role: "assistant", content: [{ type: "thinking", thinking: "隐藏" }, { type: "text", text: assistantText }] } },
        { type: "message", id: "tool-id", parentId: "answer-id", message: { role: "toolResult", toolName: "read", content: [{ type: "text", text: toolText }] } },
    ])
    const messages = readSessionHistory(file, dir)
    assert.deepEqual(messages.map((message) => message.id), ["user-id", "answer-id", "tool-id"])
    assert.equal(messages[1].text, assistantText)
    assert.equal(messages[2].text, toolText)
})

test("会话历史：工具结果保留原始调用 ID，旧记录不伪造调用 ID", (t) => {
    const { dir, file } = fixture(t, [
        { type: "session", version: 3, id: "session" },
        { type: "message", id: "result-id", parentId: null, message: { role: "toolResult", toolCallId: "t1", toolName: "read", content: [{ type: "text", text: "complete output" }] } },
        { type: "message", id: "legacy-id", parentId: "result-id", message: { role: "toolResult", toolName: "read", content: "legacy output" } },
        { type: "message", id: "invalid-id", parentId: "legacy-id", message: { role: "toolResult", toolCallId: 42, toolName: "read", content: "invalid call ID" } },
    ])
    assert.deepEqual(readSessionHistory(file, dir), [
        { id: "result-id", role: "tool", toolTitle: "read", toolCallId: "t1", text: "complete output" },
        { id: "legacy-id", role: "tool", toolTitle: "read", text: "legacy output" },
        { id: "invalid-id", role: "tool", toolTitle: "read", text: "invalid call ID" },
    ])
})

test("会话历史：工具结果保留原始调用 ID，缺失或无效 ID 不伪造", (t) => {
    const { dir, file } = fixture(t, [
        { type: "session", version: 3, id: "session" },
        { type: "message", id: "tool-id", parentId: null, message: { role: "toolResult", toolCallId: "t1", toolName: "read", content: [{ type: "text", text: "complete output" }] } },
        { type: "message", id: "legacy-tool", parentId: "tool-id", message: { role: "toolResult", toolName: "read", content: "legacy output" } },
        { type: "message", id: "invalid-tool", parentId: "legacy-tool", message: { role: "toolResult", toolCallId: 42, toolName: "read", content: "invalid id" } },
    ])
    assert.deepEqual(readSessionHistory(file, dir), [
        { id: "tool-id", role: "tool", toolTitle: "read", toolCallId: "t1", text: "complete output" },
        { id: "legacy-tool", role: "tool", toolTitle: "read", text: "legacy output" },
        { id: "invalid-tool", role: "tool", toolTitle: "read", text: "invalid id" },
    ])
})

test("会话历史：只沿最新条目的父链读取当前分支，穿过元数据节点", (t) => {
    const { dir, file } = fixture(t, [
        { type: "session", version: 3, id: "session" },
        { type: "message", id: "root", parentId: null, message: { role: "user", content: "共同问题" } },
        { type: "message", id: "old-answer", parentId: "root", message: { role: "assistant", content: "旧分支回答" } },
        { type: "message", id: "old-user", parentId: "old-answer", message: { role: "user", content: "旧分支追问" } },
        { type: "branch_summary", id: "branch", parentId: "root", fromId: "old-user", summary: "已离开的分支" },
        { type: "message", id: "new-answer", parentId: "branch", message: { role: "assistant", content: "当前回答" } },
        { type: "session_info", id: "name", parentId: "new-answer", name: "当前分支" },
    ])
    assert.deepEqual(readSessionHistory(file, dir).map(({ id, text }) => ({ id, text })), [
        { id: "root", text: "共同问题" },
        { id: "new-answer", text: "当前回答" },
    ])
})

test("会话历史：旧格式按物理行提供稳定 ID，忽略坏行但不改变已有身份", (t) => {
    const { dir, file } = fixture(t, [
        { type: "session", id: "legacy" },
        "",
        "{incomplete",
        { type: "message", message: { role: "user", content: "重复内容" } },
        { type: "model_change", modelId: "example" },
        { type: "message", message: { role: "assistant", content: "重复内容" } },
    ])
    const first = readSessionHistory(file, dir)
    assert.equal(typeof first[0].id, "string")
    assert.equal(typeof first[1].id, "string")
    assert.notEqual(first[0].id, first[1].id)
    assert.deepEqual(readSessionHistory(file, dir), first)
    appendFileSync(file, `\n${JSON.stringify({ type: "message", message: { role: "user", content: "新增" } })}`)
    assert.deepEqual(readSessionHistory(file, dir).slice(0, 2), first)
})

test("会话历史：保留最近 80 条数量上限，稳定 ID 不受窗口滑动影响", (t) => {
    const entries = [{ type: "session", id: "legacy" }]
    for (let index = 0; index < 81; index++) {
        entries.push({ type: "message", message: { role: "user", content: `消息 ${index}` } })
    }
    const { dir, file } = fixture(t, entries)
    const first = readSessionHistory(file, dir)
    assert.equal(first.length, 80)
    assert.equal(first[0].text, "消息 1")
    assert.equal(typeof first[0].id, "string")
    appendFileSync(file, `\n${JSON.stringify({ type: "message", message: { role: "user", content: "消息 81" } })}`)
    assert.deepEqual(readSessionHistory(file, dir).slice(0, 79), first.slice(1))
})

test("会话历史：窗口标记只统计当前分支可展示消息，80 条以内不截断", (t) => {
    for (const count of [0, 80, 81]) {
        const entries = [{ type: "session", version: 3, id: "session" }]
        for (let index = 0; index < 90; index++) {
            entries.push({ type: "message", id: `old-${index}`, parentId: index ? `old-${index - 1}` : null, message: { role: "user", content: "已离开的分支" } })
        }
        for (let index = 0; index < count; index++) {
            entries.push({ type: "message", id: `active-${index}`, parentId: index ? `active-${index - 1}` : null, message: { role: "user", content: `当前消息 ${index}` } })
        }
        entries.push(
            { type: "message", id: "thinking", parentId: count ? `active-${count - 1}` : null, message: { role: "assistant", content: [{ type: "thinking", thinking: "不展示" }] } },
            { type: "message", id: "blank", parentId: "thinking", message: { role: "toolResult", content: "  \n" } },
            { type: "session_info", id: "meta", parentId: "blank", name: "当前分支" },
        )
        const { dir, file } = fixture(t, entries)
        const result = history.readSessionHistoryStrict(file, dir)
        assert.equal(result.hasEarlierMessages, count > 80, `可展示消息数量 ${count}`)
        assert.equal(result.messages.length, Math.min(count, 80))
        if (count) assert.equal(result.messages[0].id, `active-${Math.max(0, count - 80)}`)
    }
})

test("会话历史：同分支锚点跨越至少 80 条新增仍保留共同消息，工具也可作为锚点", (t) => {
    for (const added of [80, 81, 160]) {
        const entries = [{ type: "session", version: 3, id: "session" }]
        for (let index = 0; index < 80; index++) {
            entries.push({ type: "message", id: `item-${index}`, parentId: index ? `item-${index - 1}` : null, message: index === 79
                ? { role: "toolResult", toolName: "read", toolCallId: "t1", content: "complete output" }
                : { role: "user", content: `消息 ${index}` } })
        }
        const { dir, file } = fixture(t, entries)
        const before = history.readSessionHistoryStrict(file, dir)
        const anchor = before.messages.at(-1)
        appendFileSync(file, Array.from({ length: added }, (_, offset) => {
            const index = 80 + offset
            return `\n${JSON.stringify({ type: "message", id: `item-${index}`, parentId: `item-${index - 1}`, message: { role: "assistant", content: `新增 ${index}` } })}`
        }).join(""))
        const window = history.readSessionHistoryStrict(file, dir)
        assert.equal(window.messages.length, 80, "原两参数调用仍为最新 80 条")
        assert.ok(!window.messages.some((message) => message.id === anchor.id))
        const result = history.readSessionHistoryStrict(file, dir, { anchorId: anchor.id })
        assert.equal(result.messages.length, added + 1)
        assert.deepEqual(result.messages[0], anchor)
        assert.equal(result.messages.at(-1).id, `item-${79 + added}`)
        assert.equal(result.hasEarlierMessages, true)
        const all = history.readSessionHistoryStrict(file, dir, { anchorId: "item-0" })
        assert.equal(all.messages.length, 80 + added)
        assert.equal(all.hasEarlierMessages, false, "返回从首条开始时未截断前缀")
        const recent = history.readSessionHistoryStrict(file, dir, { anchorId: `item-${79 + added}` })
        assert.deepEqual(recent, window, "锚点位于最近 80 条内时不缩短默认窗口")
    }
})

test("会话历史：其他分支、隐藏记录或无效锚点不扩展当前分支窗口", (t) => {
    const entries = [
        { type: "session", version: 3, id: "session" },
        { type: "message", id: "old-anchor", parentId: null, message: { role: "user", content: "旧分支" } },
    ]
    for (let index = 0; index < 100; index++) {
        entries.push({ type: "message", id: `active-${index}`, parentId: index ? `active-${index - 1}` : null, message: { role: "user", content: `新分支 ${index}` } })
    }
    entries.push({ type: "session_info", id: "metadata", parentId: "active-99", name: "当前分支" })
    const { dir, file } = fixture(t, entries)
    const expected = history.readSessionHistoryStrict(file, dir)
    assert.equal(expected.messages[0].id, "active-20")
    assert.equal(expected.hasEarlierMessages, true)
    for (const anchorId of ["old-anchor", "metadata", "missing", "", undefined, 0]) {
        assert.deepEqual(history.readSessionHistoryStrict(file, dir, { anchorId }), expected)
    }
})

test("会话历史：严格接口返回路径，空会话成功，文件与路径错误显式失败", (t) => {
    const { dir, file } = fixture(t)
    assert.deepEqual(history.readSessionHistoryStrict(file, dir), { sessionPath: file, messages: [], hasEarlierMessages: false })
    for (const invalid of [undefined, "", join(dir, "missing.jsonl"), "/etc/passwd", join(dir, "..", "outside.jsonl")]) {
        assert.throws(() => history.readSessionHistoryStrict(invalid, dir))
        assert.deepEqual(readSessionHistory(invalid, dir), [], "兼容接口仍返回数组")
    }
    const directory = join(dir, "directory.jsonl")
    mkdirSync(directory)
    assert.throws(() => history.readSessionHistoryStrict(directory, dir))
    writeFileSync(file, "not json\n{unfinished")
    assert.throws(() => history.readSessionHistoryStrict(file, dir))
})

const piResizeHint = "[Image: original 2853x2007, displayed at 2000x1407. Multiply coordinates by 1.43 to map to original image.]"
const pixel = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGM4UCDxHwAFhAJIWblWNgAAAABJRU5ErkJggg=="
const photo = { type: "image", mimeType: "image/png", data: pixel }

function photoHistory(t, messages) {
    const { dir, file } = fixture(t, [
        { type: "session", id: "photos" },
        ...messages.map((message, index) => ({ type: "message", id: String(index), message })),
    ])
    return history.readSessionHistoryStrict(file, dir).messages
}

test("图片历史保留原图或诚实占位，仅移除 Pi 添加的提示，保留用户的原始格式", t => {
    const caption = "  查看这张图。  \n"
    const literal = `请解释 ${piResizeHint}`
    const rows = photoHistory(t, [
        { role: "user", content: [{ type: "text", text: `${caption}\n\n[Image converted from image/heic to image/png.]\n${piResizeHint}` },
            { ...photo, path: "/private/example", extra: "private" }] },
        { role: "user", content: [photo] },
        { role: "user", content: `\n\n${piResizeHint}` },
        { role: "user", content: literal },
        { role: "assistant", content: [{ type: "thinking", thinking: "private" }, { type: "text", text: piResizeHint }, photo] },
        { role: "user", content: `我看到这一行：\n${piResizeHint}` },
    ])
    assert.deepEqual(rows, [
        { id: "0", role: "user", text: caption, attachments: [photo] },
        { id: "1", role: "user", text: "", attachments: [photo] },
        { id: "2", role: "user", text: "", attachments: [{ type: "image" }] },
        { id: "3", role: "user", text: literal },
        { id: "4", role: "assistant", text: piResizeHint },
        { id: "5", role: "user", text: `我看到这一行：\n${piResizeHint}` },
    ])
})

test("历史中的外部地址、伪造或过大图片仅返回占位，数量和单次总字节均受限", t => {
    const png = Buffer.from(pixel, "base64")
    const nearLimit = Buffer.concat([png, Buffer.alloc(1_100_000)]).toString("base64")
    const inputs = [
        { type: "image", url: "file:///private/example", path: "/private/example" },
        { ...photo, data: "%%%" }, { ...photo, mimeType: "image/svg+xml" },
        { ...photo, mimeType: "image/jpeg" }, { ...photo, data: Buffer.alloc(2 * 1024 * 1024 + 1).toString("base64") },
    ]
    const rows = photoHistory(t, [
        { role: "user", content: inputs },
        { role: "user", content: Array(20).fill({ type: "image" }) },
        { role: "user", content: [{ ...photo, data: nearLimit }] },
        { role: "user", content: [{ ...photo, data: nearLimit }] },
    ])
    assert.equal(rows.length, 4)
    assert.equal(rows[0].attachments.length, inputs.length)
    assert.ok(rows[0].attachments.every(item => item.type === "image" && !item.data && !item.path && !item.url))
    assert.equal(rows[1].attachments.length, 8)
    assert.equal(rows[2].attachments[0].data, undefined)
    assert.ok(rows[3].attachments[0].data === nearLimit, "先为最近消息分配本次预览预算")
})

test("工具可用调用 ID 落盘空结果并复原失败状态", t => {
    assert.deepEqual(photoHistory(t, [
        { role: "toolResult", toolCallId: "empty", toolName: "edit", content: [] },
        { role: "toolResult", toolCallId: "failed", toolName: "read", isError: true, content: "No file" },
        { role: "toolResult", toolCallId: "", toolName: "read", content: [] },
    ]), [
        { id: "0", role: "tool", toolTitle: "edit", toolCallId: "empty", text: "" },
        { id: "1", role: "tool", toolTitle: "read", toolCallId: "failed", isError: true, text: "No file" },
    ])
})

test("会话历史：不能通过目录内符号链接读取目录外文件", (t) => {
    const { dir } = fixture(t)
    const outside = fixture(t, [
        { type: "session", version: 3, id: "outside" },
        { type: "message", id: "secret", parentId: null, message: { role: "user", content: "目录外内容" } },
    ])
    const link = join(dir, "linked.jsonl")
    symlinkSync(outside.file, link)
    assert.throws(() => history.readSessionHistoryStrict(link, dir), /outside/i)
    assert.deepEqual(readSessionHistory(link, dir), [])
})
