import { readFileSync, realpathSync } from "node:fs"
import { isAbsolute, relative, resolve, sep } from "node:path"

function textFromContent(content) {
    if (typeof content === "string") return content
    if (!Array.isArray(content)) return ""
    return content
        .filter((block) => block && block.type === "text" && typeof block.text === "string")
        .map((block) => block.text)
        .join("")
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
    for (const record of tree.activeBranch().entries) {
        if (record.type !== "message" || !record.message) continue
        const message = record.message
        const role = message.role
        const body = textFromContent(message.content)
        if (!body.trim()) continue
        if (role === "user" || role === "assistant") {
            messages.push({ id: record.id, role, text: body })
        } else if (role === "toolResult") {
            const tool = { id: record.id, role: "tool", toolTitle: String(message.toolName ?? "工具"), text: body }
            if (typeof message.toolCallId === "string") tool.toolCallId = message.toolCallId
            messages.push(tool)
        }
    }
    // 默认最近 80 条；刷新时包含当前分支的旧锚点，保证长时间后台新增后仍可衔接。
    // 锚点不在当前分支或不是可展示消息时，不借用其他分支的前缀。
    let start = Math.max(0, messages.length - 80)
    const anchorIndex = typeof options?.anchorId === "string" ? messages.findIndex((message) => message.id === options.anchorId) : -1
    if (anchorIndex >= 0) start = Math.min(start, anchorIndex)
    return { sessionPath: target, messages: messages.slice(start), hasEarlierMessages: start > 0 }
}

/// 保持已有数组调用方兼容；RPC 必须使用上面的严格接口传回错误。
export function readSessionHistory(sessionPath, sessionDir) {
    try {
        return readSessionHistoryStrict(sessionPath, sessionDir).messages
    } catch {
        return []
    }
}
