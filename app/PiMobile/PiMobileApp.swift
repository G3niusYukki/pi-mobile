import SwiftUI
import PiMobileCore

@main
struct PiMobileApp: App {
    @StateObject private var model = AppModel()
    @StateObject private var scrollStore = ConversationScrollStore()
    @Environment(\.scenePhase) private var phase
    @AppStorage(PiInterfaceStyle.key) private var interfaceStyle = PiInterfaceStyle.system.rawValue

    var body: some Scene {
        WindowGroup {
            Group {
                if !model.isPaired {
                    PairingView()
                        .environment(\.colorScheme, .dark)
                } else {
                    PiRootView()
                }
            }
            .modifier(AppFontScope())
            .environmentObject(model)
            .environmentObject(scrollStore)
            .preferredColorScheme((PiInterfaceStyle(rawValue: interfaceStyle) ?? .system).colorScheme)
            .onAppear { model.bootstrap() }
            .onChange(of: phase) { _, newValue in
                if newValue == .active { model.resume() }
                if newValue == .background { model.suspendConnectionChecks() }
            }
        }
    }
}
