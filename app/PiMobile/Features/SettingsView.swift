import SwiftUI
import UIKit
import PiMobileCore

enum PiSettingsRoute: Hashable {
    case model, fontSize
}

/// Keep the existing controls until the gateway exposes model-specific capabilities.
/// Pi 1.5.2 also accepts off/minimal/medium/xhigh; its available levels vary by model.
enum PiThinkingLevel {
    static let choices: [String] = ["high", "low", "max"]

    static func title(_ value: String) -> String {
        switch value {
        case "off": return "关闭"
        case "minimal": return "极低"
        case "low": return "低"
        case "medium": return "中"
        case "high": return "高"
        case "xhigh": return "极高"
        case "max": return "最高"
        default: return value
        }
    }
}

struct PiSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage(PiInterfaceStyle.key) private var interfaceStyle = PiInterfaceStyle.system
    @AppStorage(AppFontScale.key) private var fontScale = 1.0
    @AppStorage(AppFontScale.followsSystemKey) private var fontFollowsSystem = false
    @State private var showsPairingReset = false
    let open: (PiSettingsRoute) -> Void

    init(open: @escaping (PiSettingsRoute) -> Void) {
        self.open = open
    }

    var body: some View {
        Form {
            Section {
                SettingsNavigationButton(title: "模型", value: currentModelName) { open(.model) }
                    .accessibilityIdentifier("settings-model")
                SettingsChoiceMenu(title: "思考强度", value: PiThinkingLevel.title(model.thinking)) {
                    ForEach(PiThinkingLevel.choices, id: \.self) { level in
                        Button {
                            model.setThinking(level)
                        } label: {
                            if model.thinking == level {
                                Label(PiThinkingLevel.title(level), systemImage: "checkmark")
                            } else {
                                Text(PiThinkingLevel.title(level))
                            }
                        }
                    }
                }
                .disabled(!model.canSend)
                .accessibilityIdentifier("settings-thinking")
            } header: {
                Text("当前会话").appFont(SettingsTypography.section)
            } footer: {
                Text("模型和思考强度应用到当前 Pi 会话。")
                    .appFont(SettingsTypography.description)
            }

            Section {
                LabeledContent("状态") {
                    HStack(spacing: 6) {
                        Circle().fill(connectionColor).frame(width: 7, height: 7)
                            .accessibilityHidden(true)
                        Text(connectionTitle).foregroundStyle(.secondary)
                    }
                }
                Button("重新连接") { model.reconnect() }
                    .disabled(!model.isPaired || model.connection == .connecting)
                    .accessibilityIdentifier("settings-reconnect")
            } header: {
                Text("连接").appFont(SettingsTypography.section)
            }

            Section {
                SettingsChoiceMenu(title: "外观", value: interfaceStyle.title) {
                    ForEach(PiInterfaceStyle.allCases) { style in
                        Button {
                            interfaceStyle = style
                        } label: {
                            if interfaceStyle == style {
                                Label(style.title, systemImage: "checkmark")
                            } else {
                                Text(style.title)
                            }
                        }
                    }
                }
                .accessibilityIdentifier("settings-appearance")
                SettingsNavigationButton(title: "字体大小", value: fontSizeTitle) { open(.fontSize) }
                    .accessibilityIdentifier("settings-font-size")
            } header: {
                Text("外观").appFont(SettingsTypography.section)
            }

            Section {
                LabeledContent("Pi Mobile", value: appVersion)
                LabeledContent("端到端加密", value: "手机 ↔ Mac")
            } header: {
                Text("关于 Pi").appFont(SettingsTypography.section)
            } footer: {
                Text("消息与附件在手机与已配对的 Mac 之间端到端加密。")
                    .appFont(SettingsTypography.description)
            }

            Section {
                Button("重新配对", role: .destructive) { showsPairingReset = true }
                    .disabled(!model.isPaired)
                    .accessibilityIdentifier("settings-reset-pairing")
            }
        }
        .appFont(SettingsTypography.item)
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("清除本机配对并重新扫码？", isPresented: $showsPairingReset, titleVisibility: .visible) {
            Button("清除配对", role: .destructive) { model.resetPairing() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将断开连接并移除本机保存的配对密钥。你需要重新扫描 Mac 上的二维码，Mac 上的会话会保留。")
        }
    }

    private var currentModelName: String {
        model.models.first(where: { $0.id == model.selectedModel })?.displayName
            ?? (model.selectedModel.isEmpty ? "尚未读取" : model.selectedModel)
    }

    private var fontSizeTitle: String {
        if fontFollowsSystem { return "跟随系统" }
        let scale = AppFontScale.normalized(fontScale)
        return scale == 1 ? "标准" : "\(Int((scale * 100).rounded()))%"
    }

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        guard let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String else { return version }
        return "\(version) (\(build))"
    }

    private var connectionTitle: String {
        switch model.connection {
        case .idle: return "未连接"
        case .connecting: return "正在连接"
        case .paired: return "已连接"
        case .running: return "运行中"
        case .error: return "连接异常"
        }
    }

    private var connectionColor: Color {
        switch model.connection {
        case .idle: return .secondary
        case .connecting: return Theme.amber
        case .paired, .running: return Theme.success
        case .error: return Theme.coral
        }
    }
}

struct PiSettingsDestinationView: View {
    let route: PiSettingsRoute

    var body: some View {
        switch route {
        case .model: PiModelSelectionView()
        case .fontSize: PiFontSizeSettingsView()
        }
    }
}

private struct SettingsNavigationButton: View {
    let title: LocalizedStringKey
    let value: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title).foregroundStyle(.primary)
                Spacer(minLength: 12)
                Text(verbatim: value)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Image(systemName: "chevron.right")
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(title) + Text("，") + Text(verbatim: value))
    }
}

/// Anchor the native menu to its trailing value on iPad and Duo.
private struct SettingsChoiceMenu<Content: View>: View {
    let title: LocalizedStringKey
    let value: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(spacing: 12) {
            Text(title).foregroundStyle(.primary)
            Spacer(minLength: 12)
            Menu {
                content()
            } label: {
                HStack(spacing: 8) {
                    Text(verbatim: value)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .appFont(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .tint(.primary)
            .accessibilityLabel(Text(title) + Text("，") + Text(verbatim: value))
        }
    }
}

private struct PiFontSizeSettingsView: View {
    @AppStorage(AppFontScale.key) private var fontScale = 1.0
    @AppStorage(AppFontScale.followsSystemKey) private var fontFollowsSystem = false
    @Environment(\.colorScheme) private var colorScheme
    @State private var fontFeedback = UIImpactFeedbackGenerator(style: .medium)

    private var sliderFontScale: Binding<Double> {
        Binding(
            get: { AppFontScale.normalized(fontScale) },
            set: { value in
                guard !fontFollowsSystem else { return }
                let oldTick = Int((AppFontScale.normalized(fontScale) * 20).rounded())
                let normalized = AppFontScale.normalized(value)
                let newTick = Int((normalized * 20).rounded())
                fontScale = normalized
                if oldTick != newTick {
                    fontFeedback.impactOccurred()
                    fontFeedback.prepare()
                }
            }
        )
    }

    private var bubbleColor: Color {
        colorScheme == .dark ? Color(red: 0.11, green: 0.18, blue: 0.29)
            : Color(red: 0.93, green: 0.95, blue: 1)
    }

    private var fontSizeTitle: String {
        if fontFollowsSystem { return "跟随系统" }
        let scale = AppFontScale.normalized(fontScale)
        return scale == 1 ? "标准" : "\(Int((scale * 100).rounded()))%"
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                fontSizeContent(previewHeight: max(220, geometry.size.height - 290))
                    .frame(maxWidth: 720)
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                    .padding(.bottom, 20)
                    .frame(maxWidth: .infinity)
            }
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .appFont(SettingsTypography.item)
        .navigationTitle("字体大小")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { fontScale = AppFontScale.normalized(fontScale) }
    }

    private func fontSizeContent(previewHeight: CGFloat) -> some View {
        VStack(spacing: 24) {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    HStack {
                        Spacer(minLength: 0)
                        Text("预览文字大小")
                            .appFont(SettingsTypography.item)
                            .accessibilityIdentifier("font-size-preview-title")
                            .padding(.horizontal, 18)
                            .padding(.vertical, 14)
                            .background(bubbleColor, in: UnevenRoundedRectangle(
                                topLeadingRadius: 24, bottomLeadingRadius: 24,
                                bottomTrailingRadius: 6, topTrailingRadius: 24
                            ))
                    }
                    Text("你可以拖动滑块来调整字体大小。")
                        .appFont(SettingsTypography.item)
                        .lineSpacing(6)
                    MarkdownLiteText(markdown: "调整后的字体大小会应用到所有页面，包括对话、按钮和 `代码`。")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.vertical, 32)
            }
            .frame(height: previewHeight)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))

            VStack(spacing: 16) {
                Toggle("跟随系统", isOn: $fontFollowsSystem)
                    .tint(Theme.ocean)
                    .appFont(SettingsTypography.item)
                    .accessibilityIdentifier("font-size-follow-system")
                Divider()
                VStack(spacing: 8) {
                    HStack {
                        Text(verbatim: "A").appFont(.system(size: 14, weight: .medium))
                        Spacer()
                        Text(verbatim: fontSizeTitle).appFont(SettingsTypography.item)
                        Spacer()
                        Text(verbatim: "A").appFont(.system(size: 22, weight: .medium))
                    }
                    .foregroundStyle(.secondary)
                    Slider(value: sliderFontScale, in: 0.8...1.5, step: 0.05) { editing in
                        if editing { fontFeedback.prepare() }
                    }
                    .disabled(fontFollowsSystem)
                    .tint(Color(uiColor: .systemGray3))
                    .accessibilityIdentifier("font-size-slider")
                    .accessibilityLabel("字体大小")
                    .accessibilityValue("\(Int((AppFontScale.normalized(fontScale) * 100).rounded()))%")
                    .background {
                        GeometryReader { geometry in
                            Canvas { context, size in
                                var ticks = Path()
                                let width = max(0, geometry.size.width - 28)
                                for index in 0...14 {
                                    let x = 14 + width * CGFloat(index) / 14
                                    ticks.move(to: CGPoint(x: x, y: size.height / 2 - 4))
                                    ticks.addLine(to: CGPoint(x: x, y: size.height / 2 + 4))
                                }
                                context.stroke(ticks, with: .color(Color(uiColor: .systemGray3)), lineWidth: 1.5)
                            }
                        }
                    }
                    Button("恢复默认") { fontScale = 1 }
                        .appFont(SettingsTypography.item)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("font-size-reset")
                        .padding(.vertical, 6)
                }
                .padding(.top, 12)
                .disabled(fontFollowsSystem)
                .opacity(fontFollowsSystem ? 0.45 : 1)
            }
            .padding(.horizontal, 12)
        }
    }
}

private struct PiModelSelectionView: View {
    @EnvironmentObject private var model: AppModel

    private var providers: [String] {
        Array(Set(model.models.map(\.provider))).sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("当前会话模型").appFont(SettingsTypography.title)
                    Text("选择当前 Pi 会话使用的模型，并调整思考强度。")
                        .appFont(SettingsTypography.description)
                        .foregroundStyle(.secondary)
                }

                if model.models.isEmpty {
                    emptyModels
                } else {
                    ForEach(providers, id: \.self) { provider in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(verbatim: provider)
                                .appFont(SettingsTypography.section)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 4)
                            ForEach(model.models.filter { $0.provider == provider }) { option in
                                PiModelCard(
                                    option: option,
                                    isSelected: model.selectedModel == option.id,
                                    thinking: model.thinking,
                                    select: { model.chooseModel(option) },
                                    setThinking: model.setThinking
                                )
                                .disabled(!model.canSend)
                                .opacity(!model.isConnected || model.isLoadingHistory ? 0.7 : 1)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: 1040, alignment: .leading)
            .padding(20)
            .frame(maxWidth: .infinity)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("当前会话模型")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var emptyModels: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.connection == .connecting ? "正在连接 Mac…" : "暂无可用模型")
                .appFont(SettingsTypography.item)
            Text(model.isConnected ? "Pi 尚未返回可用模型。可以重新连接以再次读取。" : "连接到 Mac 后，会在这里显示 Pi 的可用模型。")
                .appFont(SettingsTypography.description)
                .foregroundStyle(.secondary)
            Button("重新连接") { model.reconnect() }
                .appFont(SettingsTypography.item)
                .disabled(!model.isPaired || model.connection == .connecting)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }
}

private struct PiModelCard: View {
    let option: ModelOption
    let isSelected: Bool
    let thinking: String
    let select: () -> Void
    let setThinking: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                if !isSelected { select() }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(verbatim: option.displayName)
                        .appFont(SettingsTypography.item)
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                    Spacer()
                    if isSelected {
                        Text("当前使用")
                            .appFont(SettingsTypography.description.weight(.semibold))
                            .foregroundStyle(.white)
                            .fixedSize()
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(.black, in: Capsule())
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(isSelected ? "已选中" : "未选中")
            .accessibilityAddTraits(isSelected ? .isSelected : [])

            if isSelected {
                ReasoningEffortFlowLayout(spacing: 8) {
                    Text(PiThinkingLevel.choices.contains(thinking) ? "思考强度" : "思考强度 · \(PiThinkingLevel.title(thinking))")
                        .appFont(SettingsTypography.item)
                        .foregroundStyle(.secondary)
                        .fixedSize()
                    ForEach(PiThinkingLevel.choices, id: \.self) { level in
                        Button { setThinking(level) } label: {
                            Text(PiThinkingLevel.title(level))
                                .appFont(SettingsTypography.item)
                                .fixedSize()
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(thinking == level ? Color.primary : Color.secondary.opacity(0.12), in: Capsule())
                                .foregroundStyle(thinking == level ? Color(uiColor: .systemBackground) : .primary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("思考强度，\(PiThinkingLevel.title(level))")
                        .accessibilityAddTraits(thinking == level ? .isSelected : [])
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(isSelected ? Color.primary : Color.secondary.opacity(0.18), lineWidth: isSelected ? 1.5 : 1)
        }
    }
}

/// Capsules keep their natural size and wrap at card width, including in Dynamic Type.
private struct ReasoningEffortFlowLayout: Layout {
    var spacing: CGFloat = 8

    private struct Item {
        let index: Int
        let size: CGSize
    }

    private struct Row {
        var items: [Item] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = makeRows(width: proposal.width ?? .infinity, subviews: subviews)
        return CGSize(
            width: rows.map(\.width).max() ?? 0,
            height: rows.reduce(0) { $0 + $1.height } + CGFloat(max(0, rows.count - 1)) * spacing
        )
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = makeRows(width: bounds.width, subviews: subviews)
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX
            for item in row.items {
                subviews[item.index].place(
                    at: CGPoint(x: x, y: y + (row.height - item.size.height) / 2),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(item.size)
                )
                x += item.size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private func makeRows(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            let gap: CGFloat = row.items.isEmpty ? 0 : spacing
            if !row.items.isEmpty, row.width + gap + size.width > width {
                rows.append(row)
                row = Row()
            }
            row.width += (row.items.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.items.append(Item(index: index, size: size))
        }
        if !row.items.isEmpty { rows.append(row) }
        return rows
    }
}
