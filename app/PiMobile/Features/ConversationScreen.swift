import SwiftUI
import PhotosUI
import UIKit
import PiMobileCore

struct ConversationScreen: View {
    @EnvironmentObject var model: AppModel
    let onSettings: () -> Void
    @FocusState private var focused: Bool
    @State private var photoItem: PhotosPickerItem?
    @State private var photoError: String?
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
                Text("轨迹").tag(ConversationTab.trace)
            }
        } label: {
            HStack(spacing: 5) {
                Text(tab == .trace ? "工具轨迹" : model.selectedSessionTitle ?? "Pi")
                    .appFont(.headline).lineLimit(1)
                Image(systemName: "chevron.down").appFont(.caption2)
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
            .padding(.horizontal, 14)
            .padding(.bottom, 6)
        }
    }

    private func actionBanner(icon: String, text: String, actionTitle: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button(actionTitle) { action() }
                .appFont(.caption.weight(.semibold))
        }
        .appFont(.caption)
        .foregroundStyle(Theme.coral)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color(uiColor: .secondarySystemBackground))
        .padding(.horizontal, 14)
        .padding(.bottom, 6)
    }

    // MARK: - 内容

    private var content: some View {
        let rows = tab.rows(in: model.messages)
        return VStack(spacing: 0) {
            if model.isLoadingHistory {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在加载会话…")
                    Spacer()
                }
                .appFont(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
            }
            ConversationTimeline(storageKey: timelineKey, messageIDs: rows.map(\.id), isLoading: model.isLoadingHistory,
                                 submittedPromptID: tab == .chat ? model.submittedPromptID : nil) {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if rows.isEmpty, !model.isLoadingHistory {
                        if tab == .trace {
                            Label("暂无工具调用", systemImage: "wrench.and.screwdriver")
                                .appFont(.subheadline).foregroundStyle(.secondary).padding(.vertical, 16)
                        } else if model.connection != .running, model.errorMessage == nil {
                            EmptyConversationView()
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
                        if let approval = model.approvals.first {
                            ApprovalCard(request: approval) { model.answer(approval, confirmed: $0) }
                                .reservedRegionAware()
                        } else if !model.isLoadingHistory, let label = ConversationTab.activityLabel(in: model.messages, connection: model.connection, phase: model.runPhase) {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.mini).accessibilityHidden(true)
                                Text(label).appFont(.footnote)
                            }
                            .padding(.vertical, 4)
                            .foregroundStyle(.secondary)
                            .accessibilityElement(children: .combine)
                        }
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

    // MARK: - 输入区

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 4) {
            attachmentButton
            TextField("给 Pi 发消息", text: $model.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .appFont(.body)
                .foregroundStyle(.primary)
                .focused($focused)
                .lineLimit(1...5)
                .padding(.vertical, 9)
                .frame(minHeight: 44, alignment: .leading)
                .accessibilityIdentifier("composer-input")
            if focused {
                Button { focused = false } label: {
                    Image(systemName: "keyboard.chevron.compact.down").frame(width: 44, height: 44)
                }
                .accessibilityLabel("收起键盘")
            } else { modelControl }
            Button {
                if showsStopButton { model.stop() }
                else if model.send() { focused = false }
            } label: {
                Image(systemName: showsStopButton ? "stop.fill" : "arrow.up")
                    .appFont(.system(size: showsStopButton ? 13 : 16, weight: .bold))
                    .foregroundStyle(actionEnabled ? .white : Color.secondary)
                    .frame(width: 32, height: 32)
                    .background(actionEnabled ? Theme.ocean : Color(uiColor: .tertiarySystemFill), in: Circle())
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel(showsStopButton ? "停止生成" : model.connection == .running ? "发送补充消息" : "发送消息")
            .accessibilityIdentifier("composer-action")
            .disabled(!actionEnabled)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 5)
        .padding(.vertical, 3)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 22))
        .padding(.horizontal, 14)
        .padding(.top, 4)
        .padding(.bottom, 6)
        .frame(maxWidth: PiAdaptiveLayout.pageWidth)
        .frame(maxWidth: .infinity)
        .reservedRegionAware()
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

    var body: some View {
        Group {
            if message.role == .user {
                VStack(alignment: .trailing, spacing: 5) {
                    ForEach(Array(message.attachments.enumerated()), id: \.offset) { _, attachment in
                        ChatPhotoView(attachment: attachment)
                    }
                    if !message.text.isEmpty {
                        Text(message.text).textSelection(.enabled).appFont(.body)
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 15))
                    }
                }
                .padding(.leading, 34)
                .frame(maxWidth: .infinity, alignment: .trailing)
            } else {
                MarkdownLiteText(markdown: message.text, streaming: message.streaming)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .contextMenu {
            if !message.text.isEmpty {
                Button("复制全文", systemImage: "doc.on.doc") { UIPasteboard.general.string = message.text }
            }
        }
        .padding(.vertical, 4)
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
            .buttonStyle(.bordered)
        }
        .padding(14)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct EmptyConversationView: View {
    var body: some View {
        Text("还没有消息")
            .appFont(.body)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 160)
    }
}
