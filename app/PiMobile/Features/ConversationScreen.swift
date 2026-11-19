import SwiftUI
import PhotosUI
import UIKit
import PiMobileCore

struct ConversationScreen: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let onSettings: () -> Void
    @FocusState private var focused: Bool
    @State private var photoItem: PhotosPickerItem?
    @State private var photoError: String?
    @State private var tab: ConversationTab = .chat
    @State private var showsSidebar = false
    @State private var sidebarSearch = ""
    @State private var availableSize = CGSize(width: 390, height: 600)
    @State private var showsPairingReset = false
    @State private var stopRingPulse = false
    @Namespace private var composerGlassNS

    private var toolStepCount: Int {
        model.messages.reduce(0) { $0 + ($1.role == .tool ? 1 : 0) }
    }

    private var bannerStateKey: String {
        if model.needsRepair { return "repair" }
        if let notice = model.pendingDeliveryNotice { return "notice:\(notice)" }
        if let error = model.errorMessage { return "error:\(error)" }
        if !model.isConnected { return "offline:\(model.connection.rawValue)" }
        return "none"
    }

    var body: some View {
        VStack(spacing: 0) {
            banners
            content
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { composer }
        .background(Color(uiColor: .systemBackground))
        .onGeometryChange(for: CGSize.self) { $0.size } action: { availableSize = $0 }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarRole(.editor)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar { conversationToolbar }
        .buttonStyle(bouncy())
        .onAppear { consumeFocusRequest() }
        .onChange(of: model.focusComposer) { _, shouldFocus in
            if shouldFocus { consumeFocusRequest() }
        }
        .onChange(of: model.isLoadingHistory) { _, loading in
            if loading { focused = false }
        }
        .onChange(of: model.selectedSessionPath) { _, _ in focused = false }
        .onDisappear { focused = false }
        .alert("图片未发送", isPresented: Binding(get: { photoError != nil }, set: { if !$0 { photoError = nil } })) {
            Button("好") { photoError = nil }
        } message: { Text(photoError ?? "") }
        .confirmationDialog("清除本机配对并重新扫码？", isPresented: $showsPairingReset, titleVisibility: .visible) {
            Button("清除配对", role: .destructive) { model.resetPairing() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将断开连接并移除本机保存的配对密钥。Mac 上的会话会保留。")
        }
    }

    private func consumeFocusRequest() {
        guard model.focusComposer else { return }
        focused = true
        model.focusComposer = false
    }

    // MARK: - 顶部

    @ToolbarContentBuilder
    private var conversationToolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) { pageTitle }
            .sharedBackgroundVisibility(.hidden)
        if #available(iOS 27.1, *) {
            ToolbarItem(placement: .topBarTrailing) { sidebarButton }
                .axisBehavior(.verticalPreferred)
            ToolbarItem(placement: .topBarTrailing) { moreMenu }
                .axisBehavior(.verticalPreferred)
        } else {
            ToolbarItem(placement: .topBarTrailing) { sidebarButton }
            ToolbarItem(placement: .topBarTrailing) { moreMenu }
        }
    }

    private var pageTitle: some View {
        Menu {
            Picker("查看", selection: $tab) {
                Text("对话").tag(ConversationTab.chat)
                Text(toolStepCount > 0 ? "轨迹（\(toolStepCount)）" : "轨迹").tag(ConversationTab.trace)
            }
        } label: {
            HStack(spacing: 6) {
                if model.connection == .running {
                    StatusDot(color: Theme.ocean, size: 7, pulsing: true)
                        .transition(.scale.combined(with: .opacity))
                }
                Text(tab == .trace ? "工具轨迹" : model.selectedSessionTitle ?? "Pi")
                    .appFont(.headline)
                    .lineLimit(1)
                    .contentTransition(.opacity)
                if tab == .chat, toolStepCount > 0 {
                    Text("\(toolStepCount)")
                        .appFont(.caption2.weight(.semibold))
                        .foregroundStyle(Theme.ocean)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Theme.ocean.opacity(0.12), in: Capsule())
                        .contentTransition(.numericText())
                        .transition(.scale.combined(with: .opacity))
                }
                Image(systemName: "chevron.down")
                    .appFont(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(.primary)
            .animation(PiMotion.snappy(reduceMotion), value: model.connection == .running)
            .animation(PiMotion.snappy(reduceMotion), value: toolStepCount)
            .animation(PiMotion.quickFade(reduceMotion), value: tab)
        }
        .accessibilityLabel("\(model.selectedSessionTitle ?? "Pi")，切换对话或轨迹")
    }

    private var sidebarButton: some View {
        Button {
            PiHaptics.tap()
            focused = false
            showsSidebar.toggle()
            if showsSidebar { model.loadSessions() }
        } label: {
            Image(systemName: "sidebar.left").appFont(.system(size: 20))
        }
        .accessibilityLabel("展开会话侧边栏")
        .accessibilityIdentifier("conversation-sidebar-toggle")
        .popover(isPresented: $showsSidebar, arrowEdge: .top) {
            sidebar
                .presentationCompactAdaptation(.popover)
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                PiWordmark()
                Spacer()
                Button("新建会话", systemImage: "square.and.pencil") {
                    showsSidebar = false
                    model.newSession()
                }
                .labelStyle(.iconOnly)
                .disabled(!model.isConnected || model.isLoadingHistory)
            }
            PiSearchField(text: $sidebarSearch)
            ScrollView {
                LazyVStack(spacing: 8) {
                    PiSessionList(searchText: sidebarSearch) { path in
                        showsSidebar = false
                        model.switchSession(path)
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            Divider()
            Button("设置", systemImage: "gearshape") {
                showsSidebar = false
                onSettings()
            }
            .appFont(.body)
            .frame(minHeight: 44)
        }
        .padding(18)
        .frame(width: min(360, max(240, availableSize.width - 48)), height: max(240, min(620, availableSize.height - 24)))
    }

    private var moreMenu: some View {
        Menu {
            Button("新建会话", systemImage: "square.and.pencil") {
                focused = false
                model.newSession()
            }
            .disabled(!model.isConnected || model.isLoadingHistory)
            Picker("查看", selection: $tab) {
                Text("对话").tag(ConversationTab.chat)
                Text("轨迹").tag(ConversationTab.trace)
            }
            Button("设置", systemImage: "gearshape") {
                focused = false
                onSettings()
            }
            Button("刷新会话", systemImage: "arrow.clockwise") { model.loadSessions() }
            Button("重新连接", systemImage: "link") { model.reconnect() }
        } label: {
            Image(systemName: "ellipsis").appFont(.system(size: 20))
        }
        .accessibilityLabel("会话操作")
    }

    private var banners: some View {
        Group {
            if model.needsRepair {
                actionBanner(
                    icon: "key.fill",
                    text: "网关密钥已更新，请重新扫码配对",
                    actionTitle: "重新配对",
                    action: { showsPairingReset = true }
                )
                .transition(PiMotion.bannerTransition)
            } else if let notice = model.pendingDeliveryNotice {
                actionBanner(
                    icon: "clock",
                    text: notice,
                    actionTitle: "关闭",
                    tint: Theme.textSecondary,
                    action: { model.clearError() }
                )
                .transition(PiMotion.bannerTransition)
            } else if let error = model.errorMessage {
                actionBanner(
                    icon: "exclamationmark.triangle.fill",
                    text: error,
                    actionTitle: "关闭",
                    action: { model.clearError() }
                )
                .transition(PiMotion.bannerTransition)
            } else if !model.isConnected {
                HStack(spacing: 9) {
                    if model.connection == .connecting {
                        StatusDot(color: Theme.ocean, size: 7, pulsing: true)
                    } else {
                        Image(systemName: "wifi.slash")
                            .foregroundStyle(Theme.coral)
                    }
                    if model.connection == .connecting {
                        PiShimmerText(text: "正在连接 Mac…", font: .caption.weight(.medium))
                    } else {
                        Text("未连接到 Mac")
                            .appFont(.caption.weight(.medium))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    Spacer()
                    if model.connection != .connecting {
                        Button("重新连接") {
                            PiHaptics.tap()
                            model.reconnect()
                        }
                        .appFont(.caption.weight(.semibold))
                        .foregroundStyle(Theme.ocean)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Theme.cardStroke.opacity(0.6), lineWidth: 0.75)
                )
                .padding(.horizontal, 14)
                .padding(.bottom, 6)
                .transition(PiMotion.bannerTransition)
            }
        }
        .animation(PiMotion.smooth(reduceMotion), value: bannerStateKey)
    }

    private func actionBanner(icon: String, text: String, actionTitle: String, tint: Color = Theme.coral,
                              action: @escaping () -> Void) -> some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button(actionTitle) {
                PiHaptics.tap()
                action()
            }
            .appFont(.caption.weight(.semibold))
        }
        .appFont(.caption)
        .foregroundStyle(tint)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(tint == Theme.coral ? Theme.coral.opacity(0.10) : Theme.cardFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder((tint == Theme.coral ? Theme.coral : Theme.cardStroke).opacity(0.28), lineWidth: 0.75)
        )
        .padding(.horizontal, 14)
        .padding(.bottom, 6)
    }

    // MARK: - 内容

    private var content: some View {
        let rows = tab.rows(in: model.messages)
        let activityLabel = tab == .chat && !model.isLoadingHistory
            ? ConversationTab.activityLabel(in: model.messages, connection: model.connection, phase: model.runPhase)
            : nil
        return VStack(spacing: 0) {
            if model.isLoadingHistory {
                HStack(spacing: 9) {
                    StatusDot(color: Theme.ocean, size: 7, pulsing: true)
                    PiShimmerText(text: "正在加载会话…", font: .caption.weight(.medium))
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
                .transition(PiMotion.bannerTransition)
            }
            ConversationTimeline(storageKey: timelineKey, messageIDs: rows.map(\.id), isLoading: model.isLoadingHistory,
                                 isRunning: model.connection == .running,
                                 submittedPromptID: tab == .chat ? model.submittedPromptID : nil) {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if rows.isEmpty, !model.isLoadingHistory {
                        if tab == .trace {
                            Label("暂无工具调用", systemImage: "wrench.and.screwdriver")
                                .appFont(.subheadline).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, minHeight: 160)
                        } else if model.connection != .running, model.errorMessage == nil {
                            EmptyConversationView { prompt in
                                PiHaptics.selection()
                                model.draft = prompt
                                focused = true
                            }
                        }
                    }
                    ForEach(rows) { row in
                        switch row {
                        case .message(let message):
                            MessageBubble(message: message).id(row.id)
                        case .tools(let steps):
                            ToolActivityRow(group: steps, showsOutput: tab == .trace).id(row.id)
                        }
                    }
                    if tab == .chat {
                        Group {
                            if let approval = model.approvals.first {
                                ApprovalCard(request: approval) { confirmed in
                                    if confirmed { PiHaptics.success() } else { PiHaptics.stop() }
                                    model.answer(approval, confirmed: confirmed)
                                }
                                .reservedRegionAware()
                                .transition(PiMotion.cardRiseTransition)
                                .sensoryFeedback(.warning, trigger: approval.id)
                            } else if let label = activityLabel {
                                PiThinkingIndicator(label: label)
                                    .padding(.vertical, 4)
                                    .accessibilityElement(children: .combine)
                                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .leading)))
                            }
                        }
                        .animation(PiMotion.smooth(reduceMotion), value: model.approvals.first?.id)
                        .animation(PiMotion.quickFade(reduceMotion), value: activityLabel)
                    }
                }
                .padding(.top, 8)
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
                .frame(maxWidth: PiAdaptiveLayout.pageWidth)
                .frame(maxWidth: .infinity)
            }
            .id(timelineKey)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var timelineKey: String {
        "\(model.selectedSessionPath ?? model.conversationID.uuidString):\(tab)"
    }

    // MARK: - 输入区（iOS 26 液态玻璃变形输入栏）

    private var composer: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(alignment: .bottom, spacing: 4) {
                attachmentButton
                TextField(model.connection == .running ? "补充指令给 Pi…" : "给 Pi 发消息", text: $model.draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .appFont(.body)
                    .foregroundStyle(.primary)
                    .focused($focused)
                    .lineLimit(1...5)
                    .padding(.vertical, 9)
                    .frame(minHeight: 44, alignment: .leading)
                    .accessibilityIdentifier("composer-input")

                Group {
                    if focused {
                        Button {
                            PiHaptics.tap()
                            focused = false
                        } label: {
                            Image(systemName: "keyboard.chevron.compact.down")
                                .appFont(.system(size: 16, weight: .medium))
                                .frame(width: 44, height: 44)
                        }
                        .accessibilityLabel("收起键盘")
                        .transition(PiMotion.controlPopTransition)
                    } else {
                        modelControl
                            .transition(PiMotion.controlPopTransition)
                    }
                }
                .animation(PiMotion.snappy(reduceMotion), value: focused)

                composerActionButton
                    .animation(PiMotion.snappy(reduceMotion), value: showsStopButton)
                    .animation(PiMotion.snappy(reduceMotion), value: actionEnabled)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 24))
            .glassEffectID("composer-capsule", in: composerGlassNS)
        }
        .padding(.horizontal, 14)
        .padding(.top, 6)
        .padding(.bottom, 8)
        .frame(maxWidth: PiAdaptiveLayout.pageWidth)
        .frame(maxWidth: .infinity)
        .reservedRegionAware()
    }

    private var composerActionButton: some View {
        Button {
            if showsStopButton {
                PiHaptics.stop()
                model.stop()
            } else if model.send() {
                PiHaptics.send()
                focused = false
            }
        } label: {
            ZStack {
                if showsStopButton, !reduceMotion {
                    Circle()
                        .stroke(Theme.ocean.opacity(0.45), lineWidth: 1.8)
                        .frame(width: 34, height: 34)
                        .scaleEffect(stopRingPulse ? 1.24 : 0.96)
                        .opacity(stopRingPulse ? 0 : 0.75)
                }

                Circle()
                    .fill(actionButtonBackground)
                    .frame(width: 34, height: 34)

                Image(systemName: showsStopButton ? "stop.fill" : "arrow.up")
                    .appFont(.system(size: showsStopButton ? 12.5 : 15.5, weight: .bold))
                    .foregroundStyle(actionEnabled ? .white : Color.secondary)
                    .contentTransition(.symbolEffect(.replace.downUp))
            }
            .scaleEffect(actionEnabled ? 1.0 : 0.92)
            .frame(width: 44, height: 44)
        }
        .accessibilityLabel(showsStopButton ? "停止生成" : model.connection == .running ? "发送补充消息" : "发送消息")
        .accessibilityIdentifier("composer-action")
        .disabled(!actionEnabled)
        .onAppear { syncStopPulse() }
        .onChange(of: showsStopButton) { _, _ in syncStopPulse() }
        .onChange(of: reduceMotion) { _, _ in syncStopPulse() }
    }

    private var actionButtonBackground: Color {
        if showsStopButton { return Theme.ocean }
        return actionEnabled ? Theme.ocean : Color(uiColor: .tertiarySystemFill)
    }

    private func syncStopPulse() {
        stopRingPulse = false
        guard showsStopButton, !reduceMotion else { return }
        withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) {
            stopRingPulse = true
        }
    }

    private var actionEnabled: Bool {
        showsStopButton || (model.canSend && !model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private var showsStopButton: Bool {
        model.connection == .running && model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var attachmentButton: some View {
        PhotosPicker(selection: $photoItem, matching: .images) {
            Image(systemName: "plus")
                .appFont(.system(size: 20))
                .frame(width: 44, height: 44)
        }
        .buttonStyle(bouncy())
        .accessibilityLabel("发送图片")
        .disabled(!model.canSend)
        .task(id: photoItem) {
            guard let item = photoItem else { return }
            let destination = model.conversationID
            defer { if !Task.isCancelled { photoItem = nil } }
            guard let data = try? await item.loadTransferable(type: Data.self), !Task.isCancelled else {
                if !Task.isCancelled { photoError = "无法从照片图库读取图片，请再选一次。" }
                return
            }
            let jpeg = await Task.detached(priority: .userInitiated) { ChatAttachments.promptJPEG(from: data) }.value
            guard !Task.isCancelled else { return }
            guard let jpeg else { photoError = "无法读取这张图片，请换一张后重试。"; return }
            guard model.conversationID == destination, !model.isLoadingHistory else {
                photoError = "会话已切换，请在当前会话重新选择图片。"
                return
            }
            if model.send(image: jpeg) { focused = false }
            else { photoError = "会话暂时无法发送，请在连接恢复后重试。" }
        }
    }

    private var modelControl: some View {
        Menu {
            Menu("模型") {
                ForEach(model.models) { option in
                    Button {
                        PiHaptics.selection()
                        model.chooseModel(option)
                    } label: {
                        if model.selectedModel == option.id {
                            Label(option.displayName, systemImage: "checkmark")
                        } else {
                            Text(option.displayName)
                        }
                    }
                }
            }
            .disabled(model.models.isEmpty)
            Menu("思考强度") {
                ForEach(PiThinkingLevel.choices, id: \.self) { level in
                    Button {
                        PiHaptics.selection()
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
        } label: {
            HStack(spacing: 5) {
                if availableSize.width >= 480 {
                    Text(modelName).lineLimit(1).truncationMode(.tail).frame(maxWidth: 160, alignment: .trailing)
                    Image(systemName: "chevron.down").appFont(.caption2)
                } else {
                    Image(systemName: "slider.horizontal.3").appFont(.body).frame(width: 44)
                }
            }
            .appFont(.caption.weight(.medium))
            .frame(minHeight: 44)
        }
        .disabled(!model.canChangeSettings)
        .accessibilityLabel("模型与思考强度，\(modelName)，\(model.thinking)")
    }

    private var modelName: String {
        model.models.first(where: { $0.id == model.selectedModel })?.displayName
            ?? (model.selectedModel.isEmpty ? "模型" : model.selectedModel)
    }
}

// MARK: - 消息

private struct MessageBubble: View {
    let message: ChatMessage
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    private var userBubbleFill: Color {
        colorScheme == .dark
            ? Theme.ocean.opacity(0.22)
            : Theme.ocean.opacity(0.10)
    }

    var body: some View {
        Group {
            if message.role == .user {
                VStack(alignment: .trailing, spacing: 5) {
                    ForEach(Array(message.attachments.enumerated()), id: \.offset) { _, attachment in
                        ChatPhotoView(attachment: attachment)
                    }
                    if !message.text.isEmpty {
                        Text(message.text)
                            .textSelection(.enabled)
                            .appFont(.body)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .background(
                                userBubbleFill,
                                in: UnevenRoundedRectangle(
                                    topLeadingRadius: 18,
                                    bottomLeadingRadius: 18,
                                    bottomTrailingRadius: 6,
                                    topTrailingRadius: 18,
                                    style: .continuous
                                )
                            )
                    }
                }
                .padding(.leading, 34)
                .frame(maxWidth: .infinity, alignment: .trailing)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    MarkdownLiteText(markdown: message.text, streaming: message.streaming)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if !message.streaming, !message.text.isEmpty {
                        HStack(spacing: 4) {
                            PiCopyButton(text: message.text, title: "复制", compact: true)
                            Spacer()
                        }
                        .padding(.leading, -8)
                        .transition(.opacity)
                    }
                }
                .animation(PiMotion.quickFade(reduceMotion), value: message.streaming)
            }
        }
        .contextMenu {
            if !message.text.isEmpty {
                Button("复制全文", systemImage: "doc.on.doc") {
                    UIPasteboard.general.string = message.text
                    PiHaptics.success()
                }
            }
        }
        .padding(.vertical, 4)
    }
}

private struct ApprovalCard: View {
    let request: ApprovalRequest
    let answer: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "hand.raised.fill")
                    .appFont(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.amber)
                    .frame(width: 28, height: 28)
                    .background(Theme.amber.opacity(0.16), in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text("需要确认")
                        .appFont(.caption2.weight(.semibold))
                        .foregroundStyle(Theme.amber)
                    Text(request.title)
                        .appFont(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                }
            }

            if let detail = request.detail, !detail.isEmpty {
                Text(detail)
                    .appFont(.system(size: 12.5, design: .monospaced))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            HStack(spacing: 10) {
                Button {
                    answer(false)
                } label: {
                    Text("拒绝")
                        .appFont(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 42)
                        .background(Theme.cardFillStrong, in: Capsule())
                        .overlay(Capsule().strokeBorder(Theme.cardStroke, lineWidth: 0.75))
                }
                .buttonStyle(bouncy())

                Button {
                    answer(true)
                } label: {
                    Text("允许")
                        .appFont(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 42)
                        .background(Theme.ocean, in: Capsule())
                }
                .buttonStyle(bouncy())
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(uiColor: .secondarySystemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Theme.amber.opacity(0.45), lineWidth: 1)
        )
    }
}

private struct EmptyConversationView: View {
    let onPrompt: (String) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    private let suggestions = [
        ("doc.text.magnifyingglass", "检查当前仓库状态与最近改动"),
        ("wrench.and.screwdriver", "运行测试并定位失败原因"),
        ("list.bullet.clipboard", "帮我梳理接下来的实现计划"),
    ]

    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle()
                    .fill(Theme.ocean.opacity(0.12))
                    .frame(width: 72, height: 72)
                    .blur(radius: 10)
                PiMark(size: 48)
            }

            VStack(spacing: 6) {
                Text("Pi 已就绪")
                    .appFont(.title3.bold())
                    .foregroundStyle(Theme.textPrimary)
                Text("在手机上继续 Mac 会话，实时查看工具进度与代码改动。")
                    .appFont(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
            }

            VStack(spacing: 8) {
                ForEach(suggestions, id: \.1) { icon, prompt in
                    Button {
                        onPrompt(prompt)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: icon)
                                .appFont(.footnote.weight(.semibold))
                                .foregroundStyle(Theme.ocean)
                                .frame(width: 20)
                            Text(prompt)
                                .appFont(.subheadline)
                                .foregroundStyle(Theme.textPrimary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Image(systemName: "arrow.up.right")
                                .appFont(.caption2.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 11)
                        .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(Theme.cardStroke.opacity(0.55), lineWidth: 0.75)
                        )
                    }
                    .buttonStyle(bouncy())
                }
            }
            .frame(maxWidth: 420)
        }
        .padding(.vertical, 32)
        .frame(maxWidth: .infinity)
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared || reduceMotion ? 0 : 10)
        .onAppear {
            withAnimation(PiMotion.gentle(reduceMotion)) {
                appeared = true
            }
        }
    }
}
