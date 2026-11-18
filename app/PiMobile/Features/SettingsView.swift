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
                ThinkingLevelMenu()
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
        .safeAreaInset(edge: .bottom, spacing: 0) { SettingsFeedback() }
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
        .accessibilityLabel(Text("\(Text(title))，\(value)"))
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
            .accessibilityLabel(Text("\(Text(title))，\(value)"))
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

private struct SettingsFeedback: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if let error = model.settingError {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.circle").accessibilityHidden(true)
                Text(verbatim: error).frame(maxWidth: .infinity, alignment: .leading)
                Button("关闭", systemImage: "xmark", action: model.dismissSettingError)
                    .labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
            }
            .appFont(.footnote)
            .padding(.horizontal, 16)
            .background(.bar)
            .accessibilityIdentifier("settings-feedback")
        }
    }
}

private struct ThinkingLevelMenu: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        SettingsChoiceMenu(title: "思考强度", value: PiThinkingLevel.title(model.thinking)) {
            ForEach(PiThinkingLevel.choices, id: \.self) { level in
                Button { model.setThinking(level) } label: {
                    if model.thinking == level { Label(PiThinkingLevel.title(level), systemImage: "checkmark") }
                    else { Text(PiThinkingLevel.title(level)) }
                }
            }
        }
        .disabled(!model.canChangeSettings)
        .accessibilityIdentifier("settings-thinking")
    }
}

private struct PiModelSelectionView: View {
    @EnvironmentObject private var model: AppModel

    private var providers: [String] {
        Array(Set(model.models.map(\.provider))).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    var body: some View {
        Form {
            Section { ThinkingLevelMenu() }
            if model.models.isEmpty {
                Section {
                    Text(model.isConnected ? "暂无可用模型" : "连接到 Mac 后可查看模型")
                        .foregroundStyle(.secondary)
                    Button("重新连接") { model.reconnect() }
                        .disabled(!model.isPaired || model.connection == .connecting)
                }
            }
            ForEach(providers, id: \.self) { provider in
                Section {
                    ForEach(model.models.filter { $0.provider == provider }) { option in
                        let selected = model.selectedModel == option.id
                        Button { model.chooseModel(option) } label: {
                            HStack(spacing: 12) {
                                Text(verbatim: option.displayName).foregroundStyle(.primary)
                                Spacer(minLength: 8)
                                Image(systemName: "checkmark")
                                    .fontWeight(.semibold)
                                    .foregroundStyle(.tint)
                                    .opacity(selected ? 1 : 0)
                                    .accessibilityHidden(true)
                            }
                            .frame(minHeight: 30)
                            .contentShape(Rectangle())
                        }
                        .disabled(!model.canChangeSettings)
                        .accessibilityAddTraits(selected ? .isSelected : [])
                        .accessibilityIdentifier("model-option-\(option.id)")
                    }
                } header: { Text(verbatim: provider).textCase(nil) }
            }
        }
        .appFont(SettingsTypography.item)
        .safeAreaInset(edge: .bottom, spacing: 0) { SettingsFeedback() }
        .navigationTitle("模型")
        .navigationBarTitleDisplayMode(.inline)
    }
}
