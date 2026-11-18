import { closeSync, constants, createReadStream, fstatSync, lstatSync, openSync, readdirSync, realpathSync } from "node:fs"
import { join, resolve } from "node:path"
import { createInterface } from "node:readline"
import { Worker, parentPort, workerData } from "node:worker_threads"
import { createSessionTree, projectUserContent } from "./history.mjs"

const LIMIT = 50
const TITLE_LENGTH = 48
const SUMMARY_LENGTH = 110
const contextBlocks = /<(system-reminder|environment_context|environment_details|memory_capsules|navigation_graph|episodic_context|skill)\b[^>]*>[\s\S]*?(?:<\/\1\s*>|$)/gi
const filler = new Set([
  "你好", "您好", "在吗", "我在", "嗨", "哈啰", "哈喽", "谢谢", "谢谢你", "多谢", "不客气", "好", "好的", "好嘞",
  "收到", "明白", "明白了", "可以", "可以的", "嗯", "嗯嗯", "行", "继续", "继续吧", "没问题", "太好了", "辛苦了",
  "hey", "hey there", "hi", "hi there", "hello", "good morning", "good afternoon", "good evening", "thanks", "thank you",
  "thanks a lot", "thank you very much", "you're welcome", "ok", "okay", "sure", "yes", "yep", "great", "go ahead",
  "continue", "got it", "sounds good", "no problem", "how can i help", "how can i help you", "how can i help you today",
  "有什么可以帮你的吗", "有什么可以帮到你的吗",
])

function clip(text, length) {
  const chars = Array.from(text.slice(0, 2 * length + 1))
  return chars.length > length ? chars.slice(0, length - 1).join("").trimEnd() + "…" : chars.join("")
}

function topic(text) {
  const body = text.replace(/^(?:(?:请问|请(?:你)?|麻烦(?:你)?|帮我|帮忙|能不能|能否)\s*)+|^(?:please\s+|(?:can|could) you (?:please )?)/i, "")
  return (body || text).replace(/[。！？.!?]+$/, "").trim()
}

function sentences(raw) {
  // The catalog only needs short excerpts. Retain the genuine question following injected context.
  const text = raw.replace(contextBlocks, "\n").slice(0, 8192)
    .replace(/```[\s\S]*?(?:```|$)/g, "\n").replace(/<\/?user_query>/gi, "")
    .replace(/\[([^\]]+)\]\([^\s)]+\)/g, "$1").replace(/\*\*|__|`/g, "")
  const result = []
  for (const part of text.split(/\n+|(?<=[。！？])|(?<=[.!?])\s+/u)) {
    const line = part.replace(/^\s*(?:#{1,6}\s+|[-*>•]\s+|\d+[.)]\s+)/, "").replace(/\s+/g, " ").trim()
    if (!/[\p{L}\p{N}]/u.test(line)) continue
    const words = line.replace(/[.!?。！？:：]+$/u, "").split(/[，,、]+\s*/)
    if (words.every(word => filler.has(word.trim().toLowerCase().replace(/’/g, "'")))) continue
    if (/^(?:summary|conclusion|changes|next steps|概要|总结|结论|下一步)[:：]?$/i.test(line)) continue
    result.push(clip(line, SUMMARY_LENGTH + 1))
    if (result.length === 3) break
  }
  return result
}

// Project each parsed line immediately: the branch index keeps short text and parent links, never image/tool payloads.
function preview(record) {
  if (record.type === "session_info" && typeof record.name === "string") return { name: record.name.trim() }
  const message = record.message
  if (record.type !== "message" || !["user", "assistant"].includes(message?.role)) return {}
  const content = message.content
  if (message.role === "user") {
    const { text, attachments } = projectUserContent(content, undefined, "\n")
    return { role: message.role, lines: sentences(text), image: attachments.length > 0 }
  }
  if (typeof content === "string") return { role: message.role, lines: sentences(content) }
  if (!Array.isArray(content)) return {}
  const text = content.filter(block => block?.type === "text" && typeof block.text === "string").map(block => block.text).join("\n")
  return { role: message.role, lines: sentences(text) }
}

function describe({ header, entries }) {
  const named = entries.findLast(entry => entry.name)?.name
  const first = entries.find(entry => entry.role === "user" && entry.lines?.length) ?? entries.find(entry => entry.lines?.length)
  const hasImage = entries.some(entry => entry.role === "user" && entry.image)
  const title = named || (first && topic(first.lines[0])) || (hasImage ? "图片讨论" : "新会话")
  // Compare the full excerpt before clipping to keep meaningful updates that start with the topic.
  const key = s => topic(s).toLowerCase().replace(/[^\p{L}\p{N}]+/gu, "")
  const titleKey = key(title)
  let summary
  for (let i = entries.length - 1; i >= 0 && !summary; i--) {
    summary = entries[i].lines?.find(line => key(line) !== titleKey)
  }
  summary ??= hasImage ? "会话中包含图片附件。" : first ? "暂无进一步进展。" : "暂无可概括的对话内容。"
  return { cwd: typeof header?.cwd === "string" ? header.cwd : "", title: clip(title, TITLE_LENGTH), summary: clip(summary, SUMMARY_LENGTH) }
}

function children(path) {
  try { return readdirSync(path, { withFileTypes: true }) } catch { return [] }
}

function candidates(root) {
  const files = []
  function add(directory, entry) {
    if (!entry.isFile() || !entry.name.endsWith(".jsonl")) return
    const path = join(directory, entry.name)
    try {
      const stat = lstatSync(path)
      if (stat.isFile()) files.push({ path, mtime: stat.mtimeMs, fingerprint: `${stat.dev}:${stat.ino}:${stat.size}:${stat.mtimeMs}` })
    } catch { /* 一个文件消失不应影响其他会话。 */ }
  }
  for (const entry of children(root)) {
    if (!entry.isDirectory()) { add(root, entry); continue }
    const directory = join(root, entry.name)
    for (const file of children(directory)) add(directory, file)
  }
  return files.sort((a, b) => b.mtime - a.mtime || a.path.localeCompare(b.path))
}

async function readPreview(file, root, realRoot) {
  // Directory entries exclude symlinks. Recheck the full path and opened file identity before reading.
  const expectedPath = join(realRoot, file.path.slice(root.length))
  if (realpathSync(file.path) !== expectedPath) return
  const fd = openSync(file.path, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK)
  try {
    const stat = fstatSync(fd)
    if (!stat.isFile() || !stat.size || file.fingerprint !== `${stat.dev}:${stat.ino}:${stat.size}:${stat.mtimeMs}`) return
    const tree = createSessionTree(preview)
    // A live transcript may keep growing during a refresh; consume only this snapshot.
    const stream = createReadStream(file.path, { fd, autoClose: false, encoding: "utf8", end: stat.size - 1 })
    const lines = createInterface({ input: stream, crlfDelay: Infinity })
    for await (const line of lines) tree.addLine(line)
    return describe(tree.activeBranch())
  } finally { closeSync(fd) }
}

async function scan(root, cached) {
  const files = candidates(root)
  if (!files.length) return []
  const realRoot = realpathSync(root)
  const result = []
  const previous = new Map(cached.map(row => [row.path, row]))
  for (const file of files) {
    const hit = previous.get(file.path)
    if (hit?.fingerprint === file.fingerprint) result.push(hit)
    else {
      try {
        const preview = await readPreview(file, root, realRoot)
        if (preview) result.push({ ...file, ...preview })
      } catch { /* 跳过不可读或已消失的会话，不记录私人内容。 */ }
    }
    if (result.length === LIMIT) break
  }
  return result
}

// Keep one gateway root's small derived metadata in memory; concurrent refreshes of that root share the scan.
let cachedRoot, cachedRows = []
const pending = new Map()

export async function listSessionCatalog(sessionDir) {
  const root = resolve(sessionDir)
  if (!pending.has(root)) {
    const task = new Promise((resolveTask, reject) => {
      const worker = new Worker(new URL(import.meta.url), {
        execArgv: [], workerData: { catalog: true, root, cached: root === cachedRoot ? cachedRows : [] },
      })
      worker.once("message", resolveTask)
      worker.once("error", reject)
      worker.once("exit", () => reject(new Error("Session catalog worker exited without a result")))
    }).then(rows => {
      cachedRoot = root
      cachedRows = rows
      return rows.map(({ fingerprint, ...row }) => row)
    }).finally(() => pending.delete(root))
    pending.set(root, task)
  }
  return pending.get(root)
}

if (parentPort && workerData?.catalog) parentPort.postMessage(await scan(workerData.root, workerData.cached))
