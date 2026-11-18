import assert from "node:assert/strict"
import test from "node:test"
import { appendFileSync, mkdirSync, mkdtempSync, rmSync, statSync, symlinkSync, utimesSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { basename, dirname, isAbsolute, join } from "node:path"
import { listSessionCatalog } from "../src/session-catalog.mjs"

function fixture(t) {
  const root = mkdtempSync(join(tmpdir(), "pi-catalog-"))
  t.after(() => {
    assert.ok(isAbsolute(root) && basename(root).startsWith("pi-catalog-"))
    rmSync(root, { recursive: true, force: true })
  })
  return root
}

function session(root, file, entries) {
  const path = join(root, file)
  mkdirSync(dirname(path), { recursive: true })
  writeFileSync(path, entries.map(entry => typeof entry === "string" ? entry : JSON.stringify(entry)).join("\n"))
  return path
}

const header = { type: "session", version: 3, id: "s", cwd: "/work/phone-app" }
const message = (id, parentId, role, content) => ({ type: "message", id, parentId, message: { role, content } })

// A sibling's /name and answer used to be indistinguishable from active history in a flat scan.
test("目录返回真实 cwd、最近进展和当前分支最后一次人工命名", async t => {
  const root = fixture(t)
  const path = session(root, "--work-phone-app--/run.jsonl", [
    header,
    message("q", null, "user", "请检查离线同步。"),
    { type: "session_info", id: "original", parentId: "q", name: "同步排查" },
    { type: "session_info", id: "rename", parentId: "original", name: "断网后的上传" },
    message("live", "rename", "assistant", [{ type: "thinking", thinking: "内部推理" }, { type: "text", text: "重连后会继续上传队列中的照片。" }]),
    message("lost", "q", "assistant", "旧分支决定删除队列。"),
    { type: "session_info", id: "wrong-name", parentId: "lost", name: "废弃的实验" },
    "{bad line",
    { type: "branch_summary", id: "leaf", parentId: "live", summary: "也不是本分支的结论" },
    "{partial",
  ])
  assert.deepEqual(await listSessionCatalog(root), [{ path, cwd: "/work/phone-app", mtime: statSync(path).mtimeMs,
    title: "断网后的上传", summary: "重连后会继续上传队列中的照片。" }])
})

test("未命名会话从真正的中英文讨论提取话题和最近进展，过滤寒暄、工具和指令", async t => {
  const root = fixture(t)
  const zh = session(root, "--a--/a.jsonl", [
    header, message("system", null, "system", "仅供系统参考"), message("hi", "system", "user", "你好！"),
    message("q", "hi", "user", "<system-reminder>设备快照</system-reminder>\n请帮我修复离线同步。"),
    message("a", "q", "assistant", "上传队列已经恢复。"),
    message("q2", "a", "user", "还需要覆盖飞行模式。"), message("thanks", "q2", "user", "好的，谢谢！"),
    message("tool", "thanks", "toolResult", "命令输出与机密"),
    message("thinking", "tool", "assistant", [{ type: "thinking", thinking: "私有内容" }, { type: "toolCall", name: "read" }]),
  ])
  const en = session(root, "--b--/b.jsonl", [
    { ...header, cwd: "/other/phone-app" }, message("h", null, "user", "Hey there!"),
    message("q", "h", "user", "Please diagnose the upload timeout. It happens after sleep."),
    message("a", "q", "assistant", "**Fixed the reconnect timer.** The regression tests pass."),
    message("bye", "a", "assistant", "You're welcome!"),
  ])
  const rows = await listSessionCatalog(root)
  const chinese = rows.find(row => row.path === zh)
  const english = rows.find(row => row.path === en)
  assert.equal(chinese.title, "修复离线同步")
  assert.equal(chinese.summary, "还需要覆盖飞行模式。")
  assert.match(english.title, /diagnose the upload timeout/i)
  assert.equal(english.summary, "Fixed the reconnect timer.")
  assert.equal(english.cwd, "/other/phone-app")
})

test("单条用户消息尽量用第二句概括，只有一句时避免标题和概要同文", async t => {
  const root = fixture(t)
  const two = session(root, "--p--/two.jsonl", [header, { type: "message", message: { role: "user", content: "重做设置页。把主题切换放到首屏。" } }])
  const one = session(root, "--p--/one.jsonl", [header, { type: "message", message: { role: "user", content: "检查上传超时" } }])
  const rows = await listSessionCatalog(root)
  assert.equal(rows.find(row => row.path === two).summary, "把主题切换放到首屏。")
  const row = rows.find(row => row.path === one)
  assert.match(row.title, /上传超时/)
  assert.ok(row.summary && !row.summary.includes(row.title))
})

test("与标题同开头的实质进展应保留，忽略后续泛用问候", async t => {
  const root = fixture(t)
  session(root, "--p--/progress.jsonl", [header, message("q", null, "user", "离线同步"),
    message("a", "q", "assistant", "离线同步已覆盖断电恢复。"),
    message("bye", "a", "assistant", "Hi! How can I help you today?"),
  ])
  const [row] = await listSessionCatalog(root)
  assert.equal(row.summary, "离线同步已覆盖断电恢复。")
})

test("头部缺失时保留旧格式内容，无从判断的工作路径保持未知", async t => {
  const root = fixture(t)
  session(root, "--work-project-x--/legacy.jsonl", ["{broken", { type: "message", message: { role: "user", content: "排查缓存。" } }])
  session(root, "--work-project-x--/broken.jsonl", ["{broken"])
  const [row, ...rest] = await listSessionCatalog(root)
  assert.deepEqual(rest, [])
  assert.equal(row.title, "排查缓存")
  assert.equal(row.cwd, "")
})

test("图片、空会话和只有寒暄的会话有稳定回退，结果中没有图片数据或工具内容", async t => {
  const root = fixture(t)
  const image = session(root, "--p--/image.jsonl", [header, message("i", null, "user", [{ type: "image", data: "A".repeat(2_000_000), mimeType: "image/png" }])])
  const empty = session(root, "--p--/empty.jsonl", [header])
  const greetings = session(root, "--p--/greetings.jsonl", [header, message("hi", null, "user", "Hi!"), message("t", "hi", "toolResult", "秘密工具输出")])
  const rows = await listSessionCatalog(root)
  assert.equal(rows.length, 3)
  assert.match(rows.find(row => row.path === image).title, /图/)
  for (const row of rows) {
    assert.ok(row.title && row.summary && row.title !== row.summary)
    assert.doesNotMatch(row.title + row.summary, /jsonl|AAAA|秘密工具输出|Hi!/)
  }
  assert.equal(rows.find(row => row.path === empty).title, rows.find(row => row.path === greetings).title)
  assert.deepEqual(await listSessionCatalog(root), rows)
})

test("Pi 附加的坐标说明不会成为话题或概要，兼容只剩文字说明的旧照片", async t => {
  const root = fixture(t)
  const hint = "[Image: original 2853x2007, displayed at 2000x1407. Multiply coordinates by 1.43 to map to original image.]"
  const image = { type: "image", mimeType: "image/jpeg", data: "AAAA" }
  const legacy = session(root, "legacy.jsonl", [header, message("u", null, "user", hint)])
  const caption = session(root, "caption.jsonl", [header,
    message("u", null, "user", [{ type: "text", text: `核对设置页面\n\n${hint}` }, image]),
    message("a", "u", "assistant", "按钮颜色已调整。"),
    message("u2", "a", "user", [{ type: "text", text: `\n\n${hint}` }, image]),
  ])
  const entries = await listSessionCatalog(root)
  assert.equal(entries.find(row => row.path === legacy).title, "图片讨论")
  assert.equal(entries.find(row => row.path === caption).title, "核对设置页面")
  assert.equal(entries.find(row => row.path === caption).summary, "按钮颜色已调整。")
  assert.doesNotMatch(JSON.stringify(entries), /Multiply coordinates|displayed at|original 2853|AAAA/)
})

test("跨工作目录选最近 50 条并限制读取，无视软链接和非会话文件", async t => {
  const root = fixture(t)
  const outside = fixture(t)
  const start = 1_600_000_000
  const oldAccess = start - 60_000
  for (let i = 0; i < 53; i++) {
    const file = session(root, `--p${i % 2}--/${i}.jsonl`, [header])
    utimesSync(file, oldAccess, start + i)
  }
  const target = session(outside, "--foreign--/link.jsonl", [{ ...header, cwd: "/foreign" }])
  symlinkSync(target, join(root, "--p0--", "leak.jsonl"))
  symlinkSync(dirname(target), join(root, "--linked-project--"), "dir")
  session(root, "--p1--/notes.txt", [header])
  const before = statSync(join(root, "--p0--/0.jsonl")).atimeMs
  const rows = await listSessionCatalog(root)
  assert.equal(rows.length, 50)
  assert.equal(basename(rows[0].path), "52.jsonl")
  assert.equal(basename(rows.at(-1).path), "3.jsonl")
  assert.ok(rows.every(row => row.cwd === header.cwd))
  assert.equal(statSync(join(root, "--p0--/0.jsonl")).atimeMs, before)
})

test("未更改文件从缓存返回，追加消息后即使 mtime 未变也刷新概览", async t => {
  const root = fixture(t)
  const file = session(root, "--p--/session.jsonl", [header, message("q", null, "user", "排查定时器。")])
  const mtime = 1_600_000_000
  const oldAccess = mtime - 60_000
  utimesSync(file, oldAccess, mtime)
  const [before, simultaneous] = await Promise.all([listSessionCatalog(root), listSessionCatalog(root)])
  assert.deepEqual(before, simultaneous)
  utimesSync(file, oldAccess, mtime)
  await listSessionCatalog(root)
  assert.equal(statSync(file).atimeMs, oldAccess * 1000)
  appendFileSync(file, `\n${JSON.stringify(message("a", "q", "assistant", "定时器已恢复。"))}`)
  utimesSync(file, oldAccess, mtime)
  const [updated] = await listSessionCatalog(root)
  assert.equal(updated.summary, "定时器已恢复。")
})
