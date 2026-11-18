import SwiftUI
import PiMobileCore

enum ConversationTab: Hashable {
    case chat, trace

    enum Row: Identifiable {
        case message(ChatMessage), tools(ToolStepGroup)

        var id: UUID {
            switch self {
            case .message(let message): message.id
            case .tools(let group): group.id
            }
        }
    }

    func rows(in messages: [ChatMessage]) -> [Row] {
        var rows: [Row] = []
        var steps: [ChatMessage] = []
        func flush() {
            guard !steps.isEmpty else { return }
            rows.append(.tools(ToolStepGroup(steps: steps)))
            steps.removeAll(keepingCapacity: true)
        }
        for message in messages {
            if message.role == .tool {
                steps.append(message)
                if self == .trace { flush() }
            } else if self == .chat, !message.text.isEmpty || !message.attachments.isEmpty {
                flush()
                rows.append(.message(message))
            }
        }
        flush()
        return rows
    }

    static func activityLabel(in messages: [ChatMessage], connection: ConnectionState, phase: RunPhase) -> String? {
        guard connection == .running, !messages.contains(where: { $0.role == .tool && $0.toolStatus == .running }) else { return nil }
        switch phase {
        case .thinking: return "正在思考…"
        case .preparingTool: return "正在准备工具…"
        case .replying: return nil
        case .waiting: return "等待回复…"
        }
    }
}

struct ToolStepGroup: Identifiable {
    // Built from one or more adjacent tool calls. The first call anchors scroll and disclosure state.
    let steps: [ChatMessage]
    var id: UUID { steps[0].id }
    var running: [ChatMessage] { steps.filter { $0.toolStatus == .running } }
    var failed: Int { steps.filter { $0.toolStatus == .failed }.count }
    var unconfirmed: Int { steps.filter { $0.toolStatus == .unconfirmed }.count }

    var headline: String {
        if let current = running.last { return "正在\(Self.name(current))" }
        if steps.count == 1 { return Self.name(steps[0]) }
        return "\(steps.count) 个工具步骤"
    }

    var detail: String {
        if !running.isEmpty {
            if steps.count == 1 { return running[0].toolUpdates > 0 ? "已更新 \(running[0].toolUpdates) 次" : "执行中" }
            let complete = steps.count - running.count - unconfirmed
            return "\(complete)/\(steps.count) 已完成"
        }
        if failed > 0 { return steps.count == 1 ? "失败" : "\(failed) 个失败" }
        if unconfirmed > 0 { return "结果待确认" }
        return "已完成"
    }

    static func name(_ message: ChatMessage) -> String {
        switch message.toolTitle?.lowercased() {
        case "read": "读取文件"
        case "write": "写入文件"
        case "edit": "编辑文件"
        case "bash": "运行命令"
        case "grep": "搜索内容"
        case "find": "查找文件"
        case "ls": "查看目录"
        default: message.toolTitle.flatMap { $0.isEmpty ? nil : $0 } ?? "调用工具"
        }
    }
}

struct ToolActivityRow: View {
    let group: ToolStepGroup
    let showsOutput: Bool
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                expanded.toggle()
            } label: {
                HStack(spacing: 8) {
                    statusIcon
                        .frame(width: 16)
                    Text(group.headline).appFont(.subheadline.weight(.medium)).lineLimit(1)
                    Text(group.detail).appFont(.caption).foregroundStyle(.secondary)
                    Image(systemName: isOpen ? "chevron.down" : "chevron.forward")
                        .appFont(.caption2).foregroundStyle(.secondary)
                }
                .foregroundStyle(.primary)
                .frame(minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(isOpen ? "已展开" : "已收起")
            .accessibilityHint(isOpen ? "收起工具详情" : "展开查看每步状态和输出")
            if isOpen {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(group.steps) { step in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 7) {
                                Text(step.toolTitle ?? "工具").appFont(.footnote.weight(.medium))
                                Text(Self.detail(step)).appFont(.caption).foregroundStyle(.secondary)
                            }
                            if !step.text.isEmpty {
                                Text(step.text).textSelection(.enabled)
                                    .appFont(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contextMenu {
                                        Button("复制工具输出", systemImage: "doc.on.doc") { UIPasteboard.general.string = step.text }
                                    }
                            }
                        }
                    }
                }
                .padding(.leading, 12)
                .overlay(alignment: .leading) { Rectangle().fill(.quaternary).frame(width: 2) }
                .padding(.leading, 7)
                .padding(.bottom, 5)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var isOpen: Bool { showsOutput ? !expanded : expanded }

    @ViewBuilder private var statusIcon: some View {
        if !group.running.isEmpty { ProgressView().controlSize(.small) }
        else if group.failed > 0 { Image(systemName: "exclamationmark.circle").foregroundStyle(.orange) }
        else if group.unconfirmed > 0 { Image(systemName: "questionmark.circle").foregroundStyle(.secondary) }
        else { Image(systemName: "checkmark.circle").foregroundStyle(.secondary) }
    }

    private static func detail(_ step: ChatMessage) -> String {
        let state: String
        switch step.toolStatus {
        case .running: state = step.toolUpdates == 0 ? "执行中" : "执行中 · 已更新 \(step.toolUpdates) 次"
        case .finished: state = "已完成"
        case .failed: state = "失败"
        case .unconfirmed: state = "结果待确认"
        }
        guard let ms = step.toolDurationMs else { return state }
        if ms < 1000 { return "\(state) · \(ms) 毫秒" }
        let seconds = (Double(ms) / 1000).formatted(.number.precision(.fractionLength(0...1)))
        return "\(state) · \(seconds) 秒"
    }
}
