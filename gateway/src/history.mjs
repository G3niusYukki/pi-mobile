import { readFileSync, realpathSync } from "node:fs"
import { isAbsolute, relative, resolve, sep } from "node:path"

// Pi appends complete normalization hints to the prompt, separated by two line breaks.
// Match only that suffix so quotations, code and ordinary bracketed captions remain intact.
const imageHint = String.raw`\[(?:Image: original [0-9]+x[0-9]+, displayed at [0-9]+x[0-9]+\. Multiply coordinates by [0-9]+\.[0-9]+ to map to original image\.|Image converted from image/[A-Za-z0-9.+-]+ to image/[A-Za-z0-9.+-]+\.|Image omitted: could not be (?:converted to a supported inline image format|resized below the inline image size limit)\.)\]`
const hintSuffix = new RegExp(String.raw`(?:^|(?:\r?\n){2})${imageHint}(?:\r?\n${imageHint})*[ \t]*(?:\r?\n)?$`)
const photoTypes = new Set(["image/jpeg", "image/png", "image/gif", "image/webp"])
export const MAX_ATTACHMENT_BYTES = 2 * 1024 * 1024
const MAX_PHOTOS_PER_MESSAGE = 8
const RELAY_FRAME_BYTES = 12 * 1024 * 1024

function matchesPhotoType(bytes, mime) {
    switch (mime) {
        case "image/png": return bytes.subarray(0, 8).equals(Buffer.from("89504e470d0a1a0a", "hex"))
        case "image/jpeg": return bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff
        case "image/gif": return ["GIF87a", "GIF89a"].includes(bytes.toString("latin1", 0, 6))
        case "image/webp": return bytes.toString("latin1", 0, 4) === "RIFF" && bytes.toString("latin1", 8, 12) === "WEBP"
        default: return false
    }
}

function projectPhoto(block, budget) {
    const photo = { type: "image" }
    if (!photoTypes.has(block.mimeType)) return photo
    photo.mimeType = block.mimeType
    // Catalog and live echoes receive metadata only. Never resolve paths, URLs, or other producer fields.
    if (!budget || typeof block.data !== "string") return photo
    const encoded = block.data
    if (!encoded.length || encoded.length % 4 !== 0 || encoded.length + 16 > budget.wire ||
        encoded.length > 4 * Math.ceil(budget.raw / 3)) return photo
    const bytes = Buffer.from(encoded, "base64")
    if (bytes.length > budget.raw || !matchesPhotoType(bytes, photo.mimeType) || bytes.toString("base64") !== encoded) return photo
    photo.data = encoded
    budget.raw -= bytes.length
    budget.wire -= encoded.length + 16  // Includes the JSON data field.
    return photo
}

export function projectUserContent(content, budget, separator = "") {
    const rawText = textFromContent(content, separator)
    const text = rawText.includes("[Image") ? rawText.replace(hintSuffix, "") : rawText
    const attachments = []
    if (Array.isArray(content)) {
        for (const block of content) {
            if (block?.type !== "image") continue
            attachments.push(projectPhoto(block, budget))
            if (attachments.length === MAX_PHOTOS_PER_MESSAGE) break
        }
    }
    if (!attachments.length && text !== rawText) attachments.push({ type: "image" })
    return { text, attachments }
}

function textFromContent(content, separator = "") {
    if (typeof content === "string") return content
    if (!Array.isArray(content)) return ""
    return content
        .filter((block) => block && block.type === "text" && typeof block.text === "string")
        .map((block) => block.text)
        .join(separator)
}

function isWithin(root, target) {
    const rel = relative(root, target)
    return !!rel && rel !== ".." && !rel.startsWith(`..${sep}`) && !isAbsolute(rel)
}

/// 与 Pi SessionManager 重载一致：最后一个非 header 条目是 leaf，沿 parentId 回到根。
/// 目录逐行投影为短预览，历史保留完整消息；不丢弃两者都需要的元数据父链节点。
export function createSessionTree(project = record => record) {
    const byId = new Map()
    let header, leaf
    let lineNumber = 0
    return {
        addLine(line) {
            lineNumber++
            if (!line.trim()) return
            let record
            try { record = JSON.parse(line) } catch { return } // 包含正在写入的尾行
            if (!record || typeof record.type !== "string") return
            if (record.type === "session") {
                header ??= record
                return
            }
            const id = typeof record.id === "string" && record.id.length > 0 ? record.id : `line:${lineNumber}`
            // v1 没有父链；物理行 ID 不随过滤或最近 80 条窗口变化。
            const parentId = Object.hasOwn(record, "parentId") ? record.parentId : leaf?.id ?? null
            leaf = { ...project(record), id, parentId }
            byId.set(id, leaf)
        },
        activeBranch() {
            if (!header && !leaf) throw new Error("Invalid session history: no readable entries")
            const entries = []
            const seen = new Set()
            for (let entry = leaf; entry && !seen.has(entry.id); entry = byId.get(entry.parentId)) {
                entries.push(entry)
                seen.add(entry.id)
            }
            return { header, entries: entries.reverse() }
        },
    }
}

/// RPC 使用严格接口区分空会话与加载失败；返回路径供客户端核对响应归属。
export function readSessionHistoryStrict(sessionPath, sessionDir, options = {}) {
    if (typeof sessionPath !== "string" || sessionPath.length === 0) throw new Error("Invalid session path")
    const root = resolve(sessionDir)
    const target = resolve(sessionPath)
    if (!isWithin(root, target) || !target.endsWith(".jsonl")) {
        throw new Error("Session history path is outside the session directory or is not a JSONL file")
    }
    // 同时约束真实路径，防止目录内的符号链接绕过边界。
    const realTarget = realpathSync(target)
    if (!isWithin(realpathSync(root), realTarget)) {
        throw new Error("Session history path is outside the session directory")
    }

    const tree = createSessionTree()
    for (const line of readFileSync(realTarget, "utf8").split(/\r?\n/)) tree.addLine(line)
    const messages = []
    const photoSources = new Map()
    for (const record of tree.activeBranch().entries) {
        if (record.type !== "message" || !record.message) continue
        const message = record.message
        const role = message.role
        if (role === "user") {
            const { text, attachments } = projectUserContent(message.content)
            if (!attachments.length && !text.trim()) continue
            const row = { id: record.id, role, text }
            if (attachments.length) {
                row.attachments = attachments
                if (Array.isArray(message.content)) photoSources.set(record.id, message.content)
            }
            messages.push(row)
        } else if (role === "assistant") {
            const text = textFromContent(message.content)
            if (text.trim()) messages.push({ id: record.id, role, text })
        } else if (role === "toolResult") {
            const text = textFromContent(message.content)
            const callId = typeof message.toolCallId === "string" && message.toolCallId.trim() ? message.toolCallId : undefined
            if (!text.trim() && !callId) continue
            const tool = { id: record.id, role: "tool", toolTitle: String(message.toolName ?? "工具"), text }
            if (callId) tool.toolCallId = callId
            if (message.isError === true) tool.isError = true
            messages.push(tool)
        }
    }
    // 默认最近 80 条；刷新时包含当前分支的旧锚点，保证长时间后台新增后仍可衔接。
    // 锚点不在当前分支或不是可展示消息时，不借用其他分支的前缀。
    let start = Math.max(0, messages.length - 80)
    const anchorIndex = typeof options?.anchorId === "string" ? messages.findIndex((message) => message.id === options.anchorId) : -1
    if (anchorIndex >= 0) start = Math.min(start, anchorIndex)
    const result = { sessionPath: target, messages: messages.slice(start), hasEarlierMessages: start > 0 }
    if (photoSources.size) {
        // Prioritize recent photos. Leave room for the existing text, sealed base64, nonce, tag and RPC envelope.
        const budget = { raw: MAX_ATTACHMENT_BYTES, wire: Math.floor(RELAY_FRAME_BYTES * 3 / 4) - 4096 - Buffer.byteLength(JSON.stringify(result)) }
        for (let i = result.messages.length - 1; i >= 0 && budget.raw > 0 && budget.wire > 16; i--) {
            const row = result.messages[i]
            const source = photoSources.get(row.id)
            if (source) row.attachments = projectUserContent(source, budget).attachments
        }
    }
    return result
}

/// 保持已有数组调用方兼容；RPC 必须使用上面的严格接口传回错误。
export function readSessionHistory(sessionPath, sessionDir) {
    try {
        return readSessionHistoryStrict(sessionPath, sessionDir).messages
    } catch {
        return []
    }
}
