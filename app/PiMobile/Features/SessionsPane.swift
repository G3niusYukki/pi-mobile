import SwiftUI
import PiMobileCore

/// Workspace composition and native Duo toolbar follow Whaleness WorkspaceView.
struct SessionsPane: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
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
                        connectionMenu
                    }
                    .axisBehavior(.verticalPreferred)
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("设置", systemImage: "gearshape", action: onSettings)
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
                    HStack(spacing: 12) {
                        PiWordmark()
                        Spacer()
                        if !usesVerticalToolbar {
                            connectionMenu
                            PiIconButton(systemName: "gearshape", action: onSettings)
                                .accessibilityLabel("设置")
                                .accessibilityIdentifier("workspace-settings")
                        }
                    }
                    .padding(.bottom, 16)
                    if columns {
                        HStack(alignment: .top, spacing: 28) {
                            VStack(alignment: .leading, spacing: 12) {
                                searchField
                                actionButtons
                            }
                            .frame(width: min(260, geometry.size.width * 0.28), alignment: .leading)
                            Divider()
                            sessions(includesSearch: false).frame(maxWidth: .infinity)
                        }
                    } else {
                        workspaceActions
                        sessions(includesSearch: true).padding(.top, 16)
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
            .refreshable { model.loadSessions() }
        }
        .background(Theme.background())
    }

    private var connectionMenu: some View {
        Menu {
            Label(statusText, systemImage: model.isConnected ? "lock.shield" : "wifi.slash")
            Button("重新连接", systemImage: "arrow.clockwise") { model.reconnect() }
            Button("刷新会话", systemImage: "arrow.triangle.2.circlepath") { model.loadSessions() }
        } label: {
            Image(systemName: model.isConnected ? "link" : "link.badge.plus")
                .appFont(.system(size: 17, weight: .semibold))
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("连接状态：\(statusText)")
    }

    private var workspaceActions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 20) { actionButtons }
            VStack(alignment: .leading, spacing: 0) { actionButtons }
        }
    }

    @ViewBuilder private var actionButtons: some View {
        Button("新建会话", systemImage: "square.and.pencil") {
            searchIsFocused = false
            model.newSession()
        }
        .disabled(!model.isConnected || model.isLoadingHistory)
        .accessibilityIdentifier("workspace-new-session")
        .frame(minHeight: 44)
        if model.selectedSessionPath != nil || model.selectedSessionTitle != nil || !model.messages.isEmpty || !model.draft.isEmpty {
            Button("继续会话", systemImage: "arrow.turn.down.right") {
                searchIsFocused = false
                model.focusComposer = false
                model.showConversation = true
            }
            .accessibilityIdentifier("workspace-continue-session")
            .frame(minHeight: 44)
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
        let largeType = dynamicTypeSize.isAccessibilitySize
        let heading = largeType ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 8))
        return Button { open(entry.path) } label: {
            VStack(alignment: .leading, spacing: 6) {
                heading {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        if selected {
                            Image(systemName: "checkmark.circle.fill").appFont(.caption)
                                .foregroundStyle(Theme.ocean).accessibilityHidden(true)
                        }
                        Text(entry.title).appFont(.body.weight(.medium)).lineLimit(largeType ? nil : 2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if let modified = entry.modified {
                        Text(modified, style: .relative).appFont(.caption).foregroundStyle(.secondary)
                    }
                }
                if let summary = entry.summary {
                    Text(summary).appFont(.subheadline).foregroundStyle(.secondary).lineLimit(largeType ? nil : 2)
                }
            }
            .multilineTextAlignment(.leading)
            .padding(.vertical, 10)
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
