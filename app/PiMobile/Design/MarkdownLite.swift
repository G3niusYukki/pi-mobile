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
                ProgressView()
                    .controlSize(.small)
                    .tint(Theme.ocean)
                    .accessibilityLabel("Pi 正在回复")
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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(lang?.uppercased() ?? "代码")
                    .appFont(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.textTertiary)
                Spacer()
                PiCopyButton(text: code, title: "复制代码")
            }
            .padding(.horizontal, 12)
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .appFont(.system(size: 13, design: .monospaced))
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, lang == nil ? 12 : 4)
                    .padding(.bottom, lang == nil ? 0 : 10)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Theme.cardFillStrong)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Theme.cardFill, lineWidth: 1)
        )
    }
}
