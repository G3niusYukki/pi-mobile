import SwiftUI
import PiMobileCore

/// Workspace composition and native Duo toolbar follow Whaleness WorkspaceView.
struct SessionsPane: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let onSettings: () -> Void
    @State private var searchText = ""
    @FocusState private var searchIsFocused: Bool

    var body: some View {
        Group {
            if #available(iOS 27.1, *) {
                PiWorkspaceToolbarLayout { vertical in
                    workspace(usesVerticalToolbar: vertical)
                } toolbar: {
                    ToolbarItem(placement: .topBarTrailing) {
                        connectionMenu(compactIcon: true)
                    }
                    .axisBehavior(.verticalPreferred)
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("设置", systemImage: "gearshape") {
                            PiHaptics.tap()
                            onSettings()
                        }
                        .labelStyle(.iconOnly)
                        .accessibilityIdentifier("workspace-settings")
                    }
                    .axisBehavior(.verticalPreferred)
                }
            } else {
                workspace(usesVerticalToolbar: false)
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .buttonStyle(bouncy())
        .onAppear { model.loadSessions() }
    }

    private func workspace(usesVerticalToolbar: Bool) -> some View {
        GeometryReader { geometry in
            let columns = PiAdaptiveLayout.workspaceUsesColumns(
                size: geometry.size, accessibilityText: dynamicTypeSize.isAccessibilitySize
            )
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 10) {
                        PiWordmark()
                        Spacer()
                        if !usesVerticalToolbar {
                            connectionMenu(compactIcon: false)
                            PiIconButton(systemName: "gearshape") {
                                PiHaptics.tap()
                                onSettings()
                            }
                            .accessibilityLabel("设置")
                            .accessibilityIdentifier("workspace-settings")
                        }
                    }
                    .padding(.bottom, 18)
                    if columns {
                        HStack(alignment: .top, spacing: 28) {
                            VStack(alignment: .leading, spacing: 12) {
                                searchField
                                actionButtons(fullWidth: true)
                            }
                            .frame(width: min(260, geometry.size.width * 0.28), alignment: .leading)
                            Divider()
                            sessions(includesSearch: false).frame(maxWidth: .infinity)
                        }
                    } else {
                        workspaceActions
                        sessions(includesSearch: true).padding(.top, 20)
                    }
                }
                .padding(.horizontal, columns ? 40 : 22)
                .padding(.top, 18)
                .padding(.bottom, 24)
                .frame(maxWidth: PiAdaptiveLayout.workspaceWidth)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .refreshable {
                PiHaptics.tap()
                model.loadSessions()
            }
        }
        .background(Theme.background())
    }

    private var connectionColor: Color {
        switch model.connection {
        case .paired: return Theme.success
        case .running: return Theme.amber
        case .connecting: return Theme.ocean
        case .error: return Theme.coral
        case .idle: return .secondary
        }
    }

    private var connectionPulsing: Bool {
        model.connection == .running || model.connection == .connecting
    }

    private func connectionMenu(compactIcon: Bool) -> some View {
        Menu {
            Label(statusText, systemImage: model.isConnected ? "lock.shield" : "wifi.slash")
            Button("重新连接", systemImage: "arrow.clockwise") {
                PiHaptics.tap()
                model.reconnect()
            }
            Button("刷新会话", systemImage: "arrow.triangle.2.circlepath") {
                PiHaptics.tap()
                model.loadSessions()
            }
        } label: {
            if compactIcon {
                Image(systemName: model.isConnected ? "link" : "link.badge.plus")
                    .appFont(.system(size: 17, weight: .semibold))
                    .overlay(alignment: .topTrailing) {
                        StatusDot(color: connectionColor, size: 7, pulsing: connectionPulsing)
                            .offset(x: 4, y: -3)
                    }
                    .frame(width: 44, height: 44)
            } else {
                HStack(spacing: 7) {
                    StatusDot(color: connectionColor, size: 7, pulsing: connectionPulsing)
                    Text(statusText)
                        .appFont(.caption.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .contentTransition(.opacity)
                }
                .padding(.horizontal, 12)
                .frame(minHeight: 36)
                .piGlassCard(radius: 18, interactive: true)
                .animation(PiMotion.quickFade(reduceMotion), value: statusText)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("连接状态：\(statusText)")
    }

    private var hasCurrentSession: Bool {
        model.selectedSessionPath != nil || model.selectedSessionTitle != nil || !model.messages.isEmpty || !model.draft.isEmpty
    }

    private var workspaceActions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { actionButtons(fullWidth: true) }
            VStack(alignment: .leading, spacing: 10) { actionButtons(fullWidth: true) }
        }
    }

    @ViewBuilder private func actionButtons(fullWidth: Bool) -> some View {
        Button {
            PiHaptics.tap()
            searchIsFocused = false
            model.newSession()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "square.and.pencil")
                    .appFont(.subheadline.weight(.semibold))
                Text("新建会话")
                    .appFont(.subheadline.weight(.semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(Theme.onAccent)
            .padding(.horizontal, 16)
            .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: 46)
            .background(Theme.ocean, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .opacity(!model.isConnected || model.isLoadingHistory ? 0.45 : 1)
        }
        .disabled(!model.isConnected || model.isLoadingHistory)
        .accessibilityIdentifier("workspace-new-session")

        if hasCurrentSession {
            Button {
                PiHaptics.tap()
                searchIsFocused = false
                model.focusComposer = false
                model.showConversation = true
            } label: {
                HStack(spacing: 8) {
                    if model.connection == .running {
                        StatusDot(color: Theme.amber, size: 7, pulsing: true)
                    } else {
                        Image(systemName: "arrow.turn.down.right")
                            .appFont(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.ocean)
                    }
                    Text("继续会话")
                        .appFont(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 16)
                .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: 46)
                .piGlassCard(radius: 16, interactive: true)
            }
            .accessibilityIdentifier("workspace-continue-session")
            .transition(PiMotion.controlPopTransition)
        }
    }

    private var searchField: some View {
        PiSearchField(text: $searchText)
            .focused($searchIsFocused)
            .submitLabel(.search)
            .onSubmit { searchIsFocused = false }
    }

    private func sessions(includesSearch: Bool) -> some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            Text("最近会话").appFont(.title2.bold()).accessibilityAddTraits(.isHeader)
                .padding(.bottom, 12)
            if includesSearch { searchField }
            PiSessionList(searchText: searchText) { path in
                searchIsFocused = false
                model.switchSession(path)
            }
        }
    }

    private var statusText: String {
        switch model.connection {
        case .paired: return "已连接"
        case .running: return "Pi 工作中"
        case .connecting: return "连接中…"
        case .error: return "连接异常"
        case .idle: return "未连接"
        }
    }
}

/// Shared by the workspace and floating conversation sidebar.
struct PiSessionList: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let searchText: String
    let open: (String) -> Void

    var body: some View {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let folders = PiSessionFolder.grouped(model.sessions, matching: query)
        if folders.isEmpty {
            Text(query.isEmpty ? "暂无会话。连接后开始第一个任务。" : "没有匹配的会话。")
                .appFont(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 18)
        } else {
            ForEach(folders) { folder in
                Section {
                    ForEach(folder.entries) { entry in sessionRow(entry) }
                } header: {
                    folderHeader(folder)
                }
            }
        }
    }

    private func folderHeader(_ folder: PiSessionFolder) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "folder").accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(folder.name).appFont(.subheadline.weight(.semibold))
                if let parent = folder.parentPath {
                    Text(parent).appFont(.caption).foregroundStyle(.secondary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(.secondary)
        .padding(.top, 22)
        .padding(.bottom, 6)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private func sessionRow(_ entry: PiSessionEntry) -> some View {
        let selected = model.selectedSessionPath == entry.path
        let isRunningHere = selected && model.connection == .running
        let largeType = dynamicTypeSize.isAccessibilitySize
        let heading = largeType ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 8))
        return Button {
            PiHaptics.selection()
            open(entry.path)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                heading {
                    HStack(alignment: .center, spacing: 7) {
                        if isRunningHere {
                            StatusDot(color: Theme.amber, size: 7, pulsing: true)
                                .accessibilityHidden(true)
                        } else if selected {
                            Image(systemName: "checkmark.circle.fill").appFont(.caption)
                                .foregroundStyle(Theme.ocean).accessibilityHidden(true)
                        }
                        Text(entry.title).appFont(.body.weight(.medium)).lineLimit(largeType ? nil : 2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if isRunningHere {
                        Text("工作中")
                            .appFont(.caption2.weight(.semibold))
                            .foregroundStyle(Theme.amber)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Theme.amber.opacity(0.14), in: Capsule())
                    } else if let modified = entry.modified {
                        Text(modified, style: .relative).appFont(.caption).foregroundStyle(.secondary)
                    }
                }
                if let summary = entry.summary {
                    Text(summary).appFont(.subheadline).foregroundStyle(.secondary).lineLimit(largeType ? nil : 2)
                }
            }
            .multilineTextAlignment(.leading)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(bouncy())
        .foregroundStyle(.primary)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .overlay(alignment: .bottom) { Divider().accessibilityHidden(true) }
    }
}

@available(iOS 27.1, *)
private struct PiWorkspaceToolbarLayout<Content: View, Toolbar: ToolbarContent>: View {
    @Environment(\.toolbarVerticalEdge) private var verticalEdge
    @ViewBuilder let content: (Bool) -> Content
    @ToolbarContentBuilder let toolbar: () -> Toolbar

    var body: some View {
        content(verticalEdge != nil)
            .toolbar { if verticalEdge != nil { toolbar() } }
            .toolbarBackground(.hidden, for: .navigationBar)
    }
}
