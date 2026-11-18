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
                        Button("设置", systemImage: "gearshape.fill", action: onSettings)
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
                            PiIconButton(systemName: "gearshape.fill", action: onSettings)
                                .accessibilityLabel("设置")
                                .accessibilityIdentifier("workspace-settings")
                        }
                    }
                    .padding(.bottom, columns ? 48 : 44)
                    if columns {
                        HStack(alignment: .top, spacing: 36) {
                            workspaceActions.frame(width: min(440, geometry.size.width * 0.38))
                            sessions.frame(maxWidth: .infinity)
                        }
                    } else {
                        workspaceActions
                        sessions.padding(.top, 28)
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
        // Whaleness's workspace keeps its deep-ocean appearance in light mode too.
        .environment(\.colorScheme, .dark)
        .foregroundStyle(.white)
        .tint(.white)
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
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .accessibilityLabel("连接状态：\(statusText)")
    }

    private var workspaceActions: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 7) {
                Text("探索未至之境").appFont(.system(size: 32, weight: .bold))
                Text("Pi Mobile 预览版").appFont(.subheadline).foregroundStyle(.white.opacity(0.65))
            }
            HStack(spacing: 12) {
                Image(systemName: "folder").appFont(.title3).foregroundStyle(Theme.mist)
                VStack(alignment: .leading, spacing: 2) {
                    Text("全部会话").appFont(.subheadline.weight(.semibold))
                    Text("Mac · 端到端加密").appFont(.caption).foregroundStyle(.white.opacity(0.55))
                }
                Spacer()
                Circle().fill(model.isConnected ? Theme.success : Theme.coral).frame(width: 8, height: 8)
            }
            .padding(16)
            .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 15))
            .overlay(RoundedRectangle(cornerRadius: 15).stroke(.white.opacity(0.14)))
            Button {
                searchIsFocused = false
                model.newSession()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "plus.circle.fill").appFont(.title3)
                    Text("新建会话").appFont(.headline)
                    Spacer()
                    Image(systemName: "arrow.right").appFont(.subheadline)
                }
                .padding(18)
                .piGlassCard(radius: 20, tint: Theme.ocean.opacity(0.24))
            }
            .disabled(!model.isConnected || model.isLoadingHistory)
            .accessibilityIdentifier("workspace-new-session")
            if model.selectedSessionPath != nil || model.selectedSessionTitle != nil || !model.messages.isEmpty || !model.draft.isEmpty {
                Button {
                    searchIsFocused = false
                    model.focusComposer = false
                    model.showConversation = true
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "bubble.left.and.bubble.right")
                        VStack(alignment: .leading, spacing: 4) {
                            Text("继续会话").appFont(.subheadline.weight(.semibold))
                            Text(model.selectedSessionTitle ?? "当前会话")
                                .appFont(.caption).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                        }
                        Spacer()
                        Image(systemName: "arrow.right")
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 15))
                }
                .accessibilityIdentifier("workspace-continue-session")
            }
        }
    }

    private var sessions: some View {
        LazyVStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("最近会话").appFont(.headline)
                Spacer()
                Text(statusText).appFont(.caption).foregroundStyle(.white.opacity(0.6))
            }
            .padding(.bottom, 8)
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.white.opacity(0.68))
                TextField("", text: $searchText, prompt: Text("搜索会话").foregroundColor(.white.opacity(0.58)))
                    .appFont(.body)
                    .focused($searchIsFocused)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .onSubmit { searchIsFocused = false }
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).stroke(.white.opacity(0.1)))
            .padding(.bottom, 8)
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
                .padding(18)
                .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 15))
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
        .padding(.top, 8)
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
                                .foregroundStyle(Theme.success).accessibilityHidden(true)
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
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.primary.opacity(selected ? 0.09 : 0.045), in: RoundedRectangle(cornerRadius: 15))
            .contentShape(RoundedRectangle(cornerRadius: 15))
        }
        .buttonStyle(bouncy())
        .foregroundStyle(.primary)
        .accessibilityAddTraits(selected ? .isSelected : [])
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
