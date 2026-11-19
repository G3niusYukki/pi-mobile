import SwiftUI

/// 轻量 Markdown 渲染:标题/编号列表/要点/代码块/行内代码/粗体。
/// 不引入第三方依赖,覆盖助手消息 90% 的常见形态。
struct MarkdownLiteText: View {
    let markdown: String
    var streaming: Bool = false
    @AppStorage(AppFontScale.key) private var fontScale = 1.0
    @AppStorage(AppFontScale.followsSystemKey) private var fontFollowsSystem = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .codeBlock(let code, let lang):
                    CodeBlockView(code: code, lang: lang)
                case .heading(let text):
                    Text(inline(text))
                        .appFont(.system(size: 17, weight: .bold))
                        .foregroundStyle(Theme.textPrimary)
                case .numbered(let n, let text):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(n).")
                            .appFont(.system(size: 15, weight: .semibold, design: .rounded))
                            .foregroundStyle(Theme.azure)
                            .frame(minWidth: 20, alignment: .trailing)
                        Text(inline(text))
                            .foregroundStyle(Theme.textPrimary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                case .bullet(let text):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Circle().fill(Theme.textTertiary).frame(width: 4, height: 4)
                            .offset(y: -2)
                        Text(inline(text))
                            .foregroundStyle(Theme.textPrimary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                case .paragraph(let text):
                    Text(inline(text))
                        .foregroundStyle(Theme.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if streaming {
                PiStreamingCursor()
                    .padding(.top, 2)
            }
        }
        .textSelection(.enabled)
        .appFont(.system(size: 15))
        .lineSpacing(3)
    }

    // MARK: - 行内解析: `code` 与 **bold**

    private func inline(_ text: String) -> AttributedString {
        var out = AttributedString()
        var i = text.startIndex
        var buffer = ""

        func flushBuffer() {
            if !buffer.isEmpty {
                out += AttributedString(buffer)
                buffer = ""
            }
        }

        while i < text.endIndex {
            let rest = text[i...]
            if rest.hasPrefix("`") {
                if let end = text[text.index(after: i)...].firstIndex(of: "`") {
                    flushBuffer()
                    let code = String(text[text.index(after: i)..<end])
                    var run = AttributedString(code)
                    run.font = AppFont.system(size: 13.5, weight: .medium, design: .monospaced)
                        .resolved(scale: CGFloat(AppFontScale.effective(fontScale, followsSystem: fontFollowsSystem)))
                    run.foregroundColor = Theme.azure
                    run.backgroundColor = Theme.cardStroke
                    out += run
                    i = text.index(after: end)
                    continue
                }
            }
            if rest.hasPrefix("**") {
                if let range = text[text.index(i, offsetBy: 2)...].range(of: "**") {
                    flushBuffer()
                    let bold = String(text[text.index(i, offsetBy: 2)..<range.lowerBound])
                    var run = AttributedString(bold)
                    run.inlinePresentationIntent = .stronglyEmphasized
                    out += run
                    i = range.upperBound
                    continue
                }
            }
            buffer.append(text[i])
            i = text.index(after: i)
        }
        flushBuffer()
        return out
    }

    // MARK: - 块级解析

    private enum Block {
        case paragraph(String)
        case numbered(Int, String)
        case bullet(String)
        case heading(String)
        case codeBlock(String, String?)
    }

    private final class BlocksBox: NSObject {
        let blocks: [Block]
        init(_ blocks: [Block]) { self.blocks = blocks }
    }

    private static let parseCache: NSCache<NSString, BlocksBox> = {
        let cache = NSCache<NSString, BlocksBox>()
        cache.countLimit = 200
        return cache
    }()

    private var blocks: [Block] {
        let key = "\(markdown.count)-\(markdown.hashValue)" as NSString
        if let cached = Self.parseCache.object(forKey: key) {
            return cached.blocks
        }
        let parsed = parseBlocks()
        Self.parseCache.setObject(BlocksBox(parsed), forKey: key)
        return parsed
    }

    private func parseBlocks() -> [Block] {
        var result: [Block] = []
        var paragraph: [String] = []
        let lines = markdown.components(separatedBy: "\n")
        var idx = 0

        func flushParagraph() {
            let text = paragraph.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { result.append(.paragraph(text)) }
            paragraph = []
        }

        while idx < lines.count {
            let line = lines[idx]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                flushParagraph()
                let lang = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                idx += 1
                while idx < lines.count, !lines[idx].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    code.append(lines[idx])
                    idx += 1
                }
                result.append(.codeBlock(code.joined(separator: "\n"), lang.isEmpty ? nil : lang))
                idx += 1
                continue
            }

            if trimmed.isEmpty {
                flushParagraph()
                idx += 1
                continue
            }

            if trimmed.hasPrefix("# ") || trimmed.hasPrefix("## ") || trimmed.hasPrefix("### ") {
                flushParagraph()
                result.append(.heading(String(trimmed.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces))))
                idx += 1
                continue
            }

            // 数字列表 "12. xxx"
            if let dotRange = trimmed.range(of: ". "),
               trimmed[..<dotRange.lowerBound].allSatisfy(\.isNumber),
               trimmed.distance(from: trimmed.startIndex, to: dotRange.lowerBound) <= 2,
               let n = Int(trimmed[..<dotRange.lowerBound]) {
                flushParagraph()
                result.append(.numbered(n, String(trimmed[dotRange.upperBound...])))
                idx += 1
                continue
            }

            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                flushParagraph()
                result.append(.bullet(String(trimmed.dropFirst(2))))
                idx += 1
                continue
            }

            paragraph.append(trimmed)
            idx += 1
        }
        flushParagraph()
        return result
    }
}

struct CodeBlockView: View {
    let code: String
    let lang: String?

    private var isDiff: Bool {
        if let lang, ["diff", "patch"].contains(lang.lowercased()) { return true }
        let lines = code.components(separatedBy: "\n")
        let hasHunk = lines.contains { $0.hasPrefix("@@ ") }
        let hasAdd = lines.contains { $0.hasPrefix("+") && !$0.hasPrefix("+++") }
        let hasDel = lines.contains { $0.hasPrefix("-") && !$0.hasPrefix("---") }
        return hasHunk || (hasAdd && hasDel)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                HStack(spacing: 5) {
                    Image(systemName: isDiff ? "plus.forwardslash.minus" : "chevron.left.forwardslash.chevron.right")
                        .appFont(.system(size: 10, weight: .semibold))
                        .foregroundStyle(isDiff ? Theme.ocean : Theme.textTertiary)
                        .accessibilityHidden(true)
                    Text(lang?.uppercased() ?? (isDiff ? "DIFF" : "代码"))
                        .appFont(.system(size: 10.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Theme.textTertiary)
                }
                Spacer()
                PiCopyButton(text: code, title: "复制代码", compact: true)
            }
            .padding(.leading, 12)
            .padding(.trailing, 4)
            .padding(.vertical, 2)
            .background(Theme.cardFill)

            Rectangle()
                .fill(Theme.cardStroke.opacity(0.6))
                .frame(height: 0.5)

            ScrollView(.horizontal, showsIndicators: false) {
                if isDiff {
                    DiffCodeContent(code: code)
                        .padding(.vertical, 10)
                } else {
                    Text(code)
                        .appFont(.system(size: 13, design: .monospaced))
                        .foregroundStyle(Theme.textPrimary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Theme.cardFill)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Theme.cardStroke.opacity(0.7), lineWidth: 0.75)
        )
    }
}

struct DiffCodeContent: View {
    let code: String

    var body: some View {
        let lines = code.components(separatedBy: "\n")
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                let kind = LineKind(line)
                Text(line.isEmpty ? " " : line)
                    .appFont(.system(size: 12.5, design: .monospaced))
                    .foregroundStyle(kind.foreground)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 1.5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(kind.background)
            }
        }
    }

    private enum LineKind {
        case added, removed, hunk, meta, context

        init(_ line: String) {
            if line.hasPrefix("@@ ") { self = .hunk }
            else if line.hasPrefix("+++") || line.hasPrefix("---") { self = .meta }
            else if line.hasPrefix("+") { self = .added }
            else if line.hasPrefix("-") { self = .removed }
            else { self = .context }
        }

        var foreground: Color {
            switch self {
            case .added: Theme.success
            case .removed: Theme.coral
            case .hunk: Theme.ocean
            case .meta: Theme.textSecondary
            case .context: Theme.textPrimary
            }
        }

        var background: Color {
            switch self {
            case .added: Theme.success.opacity(0.11)
            case .removed: Theme.coral.opacity(0.11)
            case .hunk: Theme.ocean.opacity(0.09)
            case .meta, .context: .clear
            }
        }
    }
}
