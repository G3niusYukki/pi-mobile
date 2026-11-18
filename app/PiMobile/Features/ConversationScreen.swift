import SwiftUI
import PhotosUI
import UIKit
import PiMobileCore

private enum ConversationTab: Hashable {
    case chat, trace
}

struct ConversationScreen: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.colorScheme) private var colorScheme
    let onSettings: () -> Void
    @FocusState private var focused: Bool
    @State private var photoItem: PhotosPickerItem?
    @State private var tab: ConversationTab = .chat
    @State private var showsSidebar = false
    @State private var sidebarSearch = ""
    @State private var availableSize = CGSize(width: 390, height: 600)
    @State private var showsPairingReset = false

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
                Text("轨迹").tag(ConversationTab.trace)
            }
        } label: {
            VStack(spacing: 3) {
                HStack(spacing: 5) {
                    Text(model.selectedSessionTitle ?? "Pi")
                        .appFont(.headline).lineLimit(1)
                    Image(systemName: "chevron.down").appFont(.system(size: 9, weight: .semibold))
                }
                HStack(spacing: 4) {
                    Circle().fill(model.connection == .running ? Theme.amber : model.isConnected ? Theme.success : .gray)
                        .frame(width: 5, height: 5)
                    Text(tab == .trace ? "轨迹" : model.connection == .running ? "Pi 工作中" : "端到端加密")
                        .appFont(.caption2).foregroundStyle(.secondary)
                }
            }
            .foregroundStyle(.primary)
        }
        .accessibilityLabel("\(model.selectedSessionTitle ?? "Pi")，切换对话或轨迹")
    }

    private var sidebarButton: some View {
        Button {
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

    @ViewBuilder
    private var banners: some View {
        if model.needsRepair {
            actionBanner(
                icon: "key.fill",
                text: "网关密钥已更新，请重新扫码配对",
                actionTitle: "重新配对",
                action: { showsPairingReset = true }
            )
        } else if let error = model.errorMessage {
            actionBanner(
                icon: "exclamationmark.triangle.fill",
                text: error,
                actionTitle: "关闭",
                action: { model.clearError() }
            )
        } else if !model.isConnected {
            HStack(spacing: 8) {
                if model.connection == .connecting {
                    ProgressView().controlSize(.small).tint(Theme.ocean)
                } else {
                    Image(systemName: "wifi.slash")
                }
                Text(model.connection == .connecting ? "正在连接 Mac…" : "未连接到 Mac")
                Spacer()
                if model.connection != .connecting {
                    Button("重新连接") { model.reconnect() }
                }
            }
            .appFont(.caption)
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .piGlassCard(radius: 14)
            .padding(.horizontal, 14)
            .padding(.bottom, 6)
        }
    }

    private func actionBanner(icon: String, text: String, actionTitle: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
            Text(text)
                .lineLimit(2)
            Spacer()
            Button(actionTitle) { action() }
                .appFont(.caption.weight(.semibold))
        }
        .appFont(.caption)
        .foregroundStyle(Theme.coral)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .piGlassCard(radius: 14, tint: Theme.coral.opacity(0.10))
        .padding(.horizontal, 14)
        .padding(.bottom, 6)
    }

    // MARK: - 内容

    private var content: some View {
        VStack(spacing: 0) {
            if model.isLoadingHistory {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small).tint(Theme.ocean)
                    Text("正在加载会话…")
                    Spacer()
                }
                .appFont(.caption)
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
            }
            ConversationTimeline(
                storageKey: timelineKey,
                messageIDs: timelineMessages.map(\.id),
                isLoading: model.isLoadingHistory
            ) {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if tab == .chat {
                        if model.messages.isEmpty, !model.isLoadingHistory {
                            if let error = model.errorMessage {
                                ContentUnavailableView("会话暂不可用", systemImage: "exclamationmark.bubble", description: Text(error))
                            } else {
                                EmptyConversationView()
                            }
                        } else {
                            ForEach(model.messages) { message in
                                MessageBubble(message: message)
                                    .id(message.id)
                            }
                        }
                        if let approval = model.approvals.first {
                            ApprovalCard(request: approval) { confirmed in
                                model.answer(approval, confirmed: confirmed)
                            }
                            .reservedRegionAware()
                        }
                    } else if timelineMessages.isEmpty, !model.isLoadingHistory {
                        Label("暂无工具调用轨迹", systemImage: "waveform.path.ecg")
                            .appFont(.subheadline)
                            .foregroundStyle(Theme.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                            .piGlassCard(radius: 18)
                    } else {
                        ForEach(timelineMessages) { message in
                            MessageBubble(message: message)
                                .id(message.id)
                        }
                    }
                }
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

    private var timelineMessages: [ChatMessage] {
        tab == .chat ? model.messages : model.messages.filter { $0.toolTitle != nil }
    }

    // MARK: - 输入区

    private var composer: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("描述你想要构建的内容", text: $model.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .appFont(.body)
                .foregroundStyle(.primary)
                .focused($focused)
                .lineLimit(1...5)
                .frame(minHeight: 36, alignment: .topLeading)
                .accessibilityIdentifier("composer-input")
            HStack(spacing: 7) {
                attachmentButton
                if focused {
                    Button { focused = false } label: {
                        Image(systemName: "keyboard.chevron.compact.down")
                            .appFont(.system(size: 17))
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("收起键盘")
                }
                Spacer(minLength: 2)
                modelControl
                Button {
                    if showsStopButton {
                        model.stop()
                    } else if model.send() {
                        focused = false
                    }
                } label: {
                    Image(systemName: showsStopButton ? "stop.fill" : "arrow.up")
                        .appFont(.system(size: showsStopButton ? 14 : 17, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 42, height: 42)
                        .background(Theme.ocean, in: Circle())
                }
                .buttonStyle(bouncy())
                .accessibilityLabel(showsStopButton ? "停止生成" : model.connection == .running ? "发送补充消息" : "发送消息")
                .accessibilityIdentifier("composer-action")
                .disabled(!showsStopButton && (model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !model.canSend))
            }
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .piGlassCard(radius: 24)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24).stroke(.primary.opacity(0.08), lineWidth: 0.7))
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.24 : 0.10), radius: 10, x: 0, y: 2)
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
        .frame(maxWidth: PiAdaptiveLayout.pageWidth)
        .frame(maxWidth: .infinity)
        .reservedRegionAware()
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
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task {
                guard let data = try? await item.loadTransferable(type: Data.self),
                      let image = UIImage(data: data) else { return }
                let compressed = image.jpegData(compressionQuality: 0.7) ?? data
                if model.send(image: compressed) {
                    focused = false
                    photoItem = nil
                }
            }
        }
    }

    private var modelControl: some View {
        Menu {
            Menu("模型") {
                ForEach(model.models) { option in
                    Button { model.chooseModel(option) } label: {
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
                    Button { model.setThinking(level) } label: {
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
                Text(shortModelName).lineLimit(1).layoutPriority(-1)
                Text(model.thinking.uppercased())
                    .appFont(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.purple)
                    .padding(.horizontal, 5).padding(.vertical, 3)
                    .background(Theme.purple.opacity(0.12), in: Capsule())
                Image(systemName: "chevron.up.chevron.down").appFont(.system(size: 9, weight: .semibold))
            }
            .appFont(.caption.weight(.medium))
            .frame(minHeight: 44)
        }
        .disabled(!model.canSend)
        .accessibilityLabel("模型与思考强度，\(shortModelName)，\(model.thinking)")
    }

    private var shortModelName: String {
        let name = model.models.first(where: { $0.id == model.selectedModel })?.displayName
            ?? (model.selectedModel.isEmpty ? "模型" : model.selectedModel)
        return name.count > 18 ? String(name.prefix(18)) + "…" : name
    }
}

// MARK: - 消息

private struct MessageBubble: View {
    let message: ChatMessage
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 7) {
            switch message.role {
            case .user:
                Text(message.text)
                    .textSelection(.enabled)
                    .appFont(.body)
                    .foregroundStyle(.primary)
                    .padding(10)
                    .background(Theme.ocean.opacity(colorScheme == .dark ? 0.24 : 0.11), in: RoundedRectangle(cornerRadius: 15))
                    .overlay(RoundedRectangle(cornerRadius: 15).stroke(Theme.ocean.opacity(colorScheme == .dark ? 0.34 : 0.08), lineWidth: 0.7))
            case .assistant:
                MarkdownLiteText(markdown: message.text, streaming: message.streaming)
                    .frame(maxWidth: .infinity, alignment: .leading)
            case .tool:
                VStack(alignment: .leading, spacing: 8) {
                    Label(message.toolTitle ?? "工具", systemImage: "wrench.and.screwdriver")
                        .appFont(.caption.weight(.semibold))
                        .foregroundStyle(Theme.amber)
                    if !message.text.isEmpty {
                        Text(message.text)
                            .textSelection(.enabled)
                            .appFont(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 11))
            }
            if !message.text.isEmpty {
                PiCopyButton(text: message.text, title: "复制全文")
            }
        }
        .padding(.leading, message.role == .user ? 34 : 0)
        .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
        .padding(.vertical, 12)
    }
}

private struct ApprovalCard: View {
    let request: ApprovalRequest
    let answer: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(request.title, systemImage: "hand.raised.fill")
                .appFont(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
            if let detail = request.detail {
                Text(detail)
                    .appFont(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
            HStack(spacing: 10) {
                Button("拒绝") { answer(false) }
                    .frame(maxWidth: .infinity)
                Button("允许") { answer(true) }
                    .frame(maxWidth: .infinity)
            }
            .appFont(.subheadline.weight(.semibold))
            .foregroundStyle(Theme.textPrimary)
            .padding(.vertical, 10)
            .piGlassCard(radius: 14, tint: Theme.ocean.opacity(0.18))
        }
        .padding(14)
        .piGlassCard(radius: 20, tint: Theme.amber.opacity(0.10))
    }
}

private struct EmptyConversationView: View {
    var body: some View {
        VStack(spacing: 14) {
            PiMark(size: 64)
            Text("还没有消息")
                .appFont(.headline)
                .foregroundStyle(Theme.textPrimary)
            Text("给 Pi 发条消息，开始这次会话。")
                .appFont(.subheadline)
                .foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity, minHeight: 260)
        .padding(24)
        .piGlassCard(radius: 24)
        .padding(.top, 30)
    }
}
