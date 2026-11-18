import SwiftUI

/// Whaleness keeps workspace, conversation and settings in one navigation stack.
/// The conversation's viewport stays owned by ConversationScrollStore when popped.
struct PiRootView: View {
    @EnvironmentObject private var model: AppModel
    @State private var path: [PiRoute] = []

    var body: some View {
        NavigationStack(path: $path) {
            SessionsPane(onSettings: { path.append(.settings) })
                .navigationDestination(for: PiRoute.self) { route in
                    switch route {
                    case .conversation:
                        ConversationScreen(onSettings: { path.append(.settings) })
                    case .settings:
                        PiSettingsView(open: { path.append(.settingsDetail($0)) })
                    case .settingsDetail(let destination):
                        PiSettingsDestinationView(route: destination)
                    }
                }
        }
        .tint(Theme.ocean)
        .onAppear { showRequestedConversation() }
        .onChange(of: model.showConversation) { _, requested in
            if requested { showRequestedConversation() }
        }
        .onChange(of: path) { _, routes in
            model.showConversation = routes.contains(.conversation)
        }
    }

    private func showRequestedConversation() {
        guard model.showConversation, !path.contains(.conversation) else { return }
        path.append(.conversation)
    }
}

private enum PiRoute: Hashable {
    case conversation
    case settings
    case settingsDetail(PiSettingsRoute)
}

/// The same window-based breakpoints as Whaleness, including unfolded Duo landscape.
enum PiAdaptiveLayout {
    static let pageWidth: CGFloat = 1_040
    static let workspaceWidth: CGFloat = 1_440

    static func workspaceUsesColumns(size: CGSize, accessibilityText: Bool = false) -> Bool {
        guard !accessibilityText, size.height >= 500 else { return false }
        return size.width >= 900 || (size.width >= 700 && size.width > size.height)
    }
}
