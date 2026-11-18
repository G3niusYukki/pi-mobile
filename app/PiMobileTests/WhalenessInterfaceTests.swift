import XCTest
import SwiftUI
import PiMobileCore
@testable import PiMobile

/// Host the production views without pairing or sending any network command.
@MainActor
final class WhalenessInterfaceTests: XCTestCase {
    private var window: UIWindow?
    private var previousWindow: UIWindow?
    private var preferences: [String: Any] = [:]
    private let preferenceKeys = [AppFontScale.key, AppFontScale.followsSystemKey, PiInterfaceStyle.key]

    override func setUp() {
        super.setUp()
        for key in preferenceKeys { preferences[key] = UserDefaults.standard.object(forKey: key) }
        UserDefaults.standard.set(1.0, forKey: AppFontScale.key)
        UserDefaults.standard.set(false, forKey: AppFontScale.followsSystemKey)
    }

    override func tearDown() {
        window?.isHidden = true
        window?.rootViewController = nil
        window = nil
        previousWindow?.makeKey()
        previousWindow = nil
        for key in preferenceKeys {
            if let value = preferences[key] { UserDefaults.standard.set(value, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        preferences = [:]
        super.tearDown()
    }

    func testBackAndReopenConversationUsesOneNativeStack() async throws {
        let model = await fixtureModel()
        model.selectedSessionPath = nil
        model.selectedSessionTitle = "新建会话"
        model.messages = []
        model.sessions = []
        model.draft = "未发送的草稿"
        let conversationID = model.conversationID
        let host = try await host(PiRootView().environmentObject(model).environmentObject(ConversationScrollStore()),
                                  size: CGSize(width: 390, height: 844), style: .light)
        let nav = try XCTUnwrap(findNavigation(in: host))
        XCTAssertEqual(nav.viewControllers.count, 1)
        model.showConversation = true
        try await eventually { nav.viewControllers.count == 2 }
        nav.popViewController(animated: false)
        try await eventually { !model.showConversation && nav.viewControllers.count == 1 }
        model.showConversation = true
        try await eventually { nav.viewControllers.count == 2 }
        model.messages.append(ChatMessage(role: .assistant, text: "新的回复"))
        await settle()
        XCTAssertEqual(nav.viewControllers.count, 2, "A reply must not push a second conversation screen")
        XCTAssertFalse(model.focusComposer, "Returning to history must not request the keyboard")
        XCTAssertEqual(model.draft, "未发送的草稿")
        XCTAssertEqual(model.conversationID, conversationID, "Reopening must preserve an unsaved native session")
        XCTAssertNil(model.selectedSessionPath)
    }

    func testCatalogArrivingAfterHistoryUpdatesTheOpenConversationTitle() async {
        let model = await fixtureModel()
        model.selectedSessionTitle = "当前会话"
        model.applySessionList([
            ["path": "/preview/session-two.jsonl", "cwd": "/projects/pi-mobile", "title": "修复键盘遮挡"],
            ["path": "/preview/pi-session.jsonl", "cwd": "/projects/pi-mobile", "title": "调整会话分组", "summary": "历史会话按工作目录排列。"],
        ])
        XCTAssertEqual(model.selectedSessionPath, "/preview/pi-session.jsonl")
        XCTAssertEqual(model.selectedSessionTitle, "调整会话分组")
        XCTAssertEqual(model.sessionTitle(for: "/preview/session-two.jsonl"), "修复键盘遮挡")
        model.applySessionList([])
        XCTAssertEqual(model.selectedSessionTitle, "调整会话分组", "An open session can fall outside the recent catalog.")
    }

    func testChangingFontPreferenceReflowsExistingMarkdown() async throws {
        let measurement = FontMeasurement()
        _ = try await host(FontMeasurementView(measurement: measurement).modifier(AppFontScope()),
                           size: CGSize(width: 390, height: 844), style: .light)
        let initial = measurement.height
        XCTAssertGreaterThan(initial, 20)
        UserDefaults.standard.set(1.5, forKey: AppFontScale.key)
        try await eventually { measurement.height > initial * 1.3 }
        UserDefaults.standard.set(true, forKey: AppFontScale.followsSystemKey)
        try await eventually { abs(measurement.height - initial) < 2 }
    }

    func testWorkspaceAdaptsToDuoAndAccessibilitySizes() {
        XCTAssertFalse(PiAdaptiveLayout.workspaceUsesColumns(size: CGSize(width: 390, height: 844)))
        XCTAssertTrue(PiAdaptiveLayout.workspaceUsesColumns(size: CGSize(width: 1024, height: 768)))
        XCTAssertTrue(PiAdaptiveLayout.workspaceUsesColumns(size: CGSize(width: 760, height: 540)))
        XCTAssertFalse(PiAdaptiveLayout.workspaceUsesColumns(size: CGSize(width: 1024, height: 400)))
        XCTAssertFalse(PiAdaptiveLayout.workspaceUsesColumns(size: CGSize(width: 1024, height: 768), accessibilityText: true))
    }

    func testRenderWorkspaceConversationAndSettingDestinations() async throws {
        let model = await fixtureModel()
        let store = ConversationScrollStore()
        let narrow = CGSize(width: 390, height: 844)
        let wide = CGSize(width: 1024, height: 768)
        try await snapshot("workspace-narrow", size: narrow, style: .dark, model: model, store: store) {
            SessionsPane(onSettings: {})
        }
        try await snapshot("workspace-wide", size: wide, style: .dark, model: model, store: store) {
            SessionsPane(onSettings: {})
        }
        model.errorMessage = nil
        XCTAssertEqual(model.messages.count, 2, "Rendered conversation must contain the supplied history")
        try await snapshot("conversation-light", size: narrow, style: .light, model: model, store: store) {
            ConversationScreen(onSettings: {})
        }
        try await snapshot("conversation-dark-wide", size: wide, style: .dark, model: model, store: store) {
            ConversationScreen(onSettings: {})
        }
        try await snapshot("settings-light", size: narrow, style: .light, model: model, store: store) {
            PiSettingsView(open: { _ in })
        }
        try await snapshot("models-dark", size: narrow, style: .dark, model: model, store: store) {
            PiSettingsDestinationView(route: .model)
        }
        UserDefaults.standard.set(1.3, forKey: AppFontScale.key)
        try await snapshot("font-preview-light", size: narrow, style: .light, model: model, store: store) {
            PiSettingsDestinationView(route: .fontSize)
        }
    }

    private func fixtureModel() async -> AppModel {
        let model = AppModel()
        // Let the initial disconnected publisher settle before applying synthetic history.
        await settle()
        model.selectedSessionPath = "/preview/pi-session.jsonl"
        model.selectedSessionTitle = "Pi 界面设计"
        model.models = [
            ModelOption(provider: "OpenAI", modelId: "gpt-6-astra", displayName: "GPT-6 Astra"),
            ModelOption(provider: "OpenAI", modelId: "gpt-5.4", displayName: "GPT-5.4"),
            ModelOption(provider: "Anthropic", modelId: "claude-opus-4-7", displayName: "Claude Opus 4.7"),
        ]
        model.selectedModel = model.models[0].id
        model.sessions = [
            ["path": "/preview/pi-session.jsonl", "title": "Pi 界面设计", "cwd": "/projects/pi-mobile", "summary": "工作区按文件夹归类，会话浮窗也能搜索讨论内容。"],
            ["path": "/preview/session-two.jsonl", "title": "检查代码并完成测试", "cwd": "/projects/pi-mobile"],
            ["path": "/preview/session-three.jsonl", "title": "整理本周的开发计划", "cwd": "/projects/workspace"],
        ]
        model.messages = [
            ChatMessage(role: .user, text: "参考 Whaleness 的界面，布局和设置复用，品牌换成 Pi。"),
            ChatMessage(role: .assistant, text: "已经统一为 **Pi** 的界面。\n\n- 工作区按屏幕宽度排列\n- 设置和字体调整使用原生导航\n- 对话保留阅读位置\n\n```swift\nText(\"你好，Pi\")\n```"),
        ]
        return model
    }

    private func snapshot<Content: View>(_ name: String, size: CGSize, style: UIUserInterfaceStyle,
                                         model: AppModel, store: ConversationScrollStore,
                                         @ViewBuilder content: () -> Content) async throws {
        _ = try await host(NavigationStack { content() }
            .modifier(AppFontScope()).environmentObject(model).environmentObject(store), size: size, style: style)
        let window = try XCTUnwrap(window)
        XCTAssertGreaterThan(window.bounds.width, 0)
        XCTAssertGreaterThan(window.bounds.height, 0)
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func host<Content: View>(_ content: Content, size: CGSize, style: UIUserInterfaceStyle) async throws -> UIViewController {
        window?.isHidden = true
        window?.rootViewController = nil
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        if previousWindow == nil { previousWindow = scene.windows.first(where: \.isKeyWindow) }
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        window.overrideUserInterfaceStyle = style
        let host = UIHostingController(rootView: content)
        window.rootViewController = host
        window.makeKeyAndVisible()
        self.window = window
        await settle()
        return host
    }

    private func findNavigation(in controller: UIViewController) -> UINavigationController? {
        if let nav = controller as? UINavigationController { return nav }
        return controller.children.lazy.compactMap { self.findNavigation(in: $0) }.first
    }

    private func settle() async { try? await Task.sleep(for: .milliseconds(350)) }

    private func eventually(_ condition: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(30))
        }
        XCTFail("The production interface did not reach the expected state")
        throw InterfaceTestError.timedOut
    }
}

private enum InterfaceTestError: Error { case timedOut }

@MainActor
private final class FontMeasurement { var height: CGFloat = 0 }

private struct FontMeasurementView: View {
    let measurement: FontMeasurement
    var body: some View {
        MarkdownLiteText(markdown: "字体调整需要更新 **正文** 和 `行内代码`。" + String(repeating: "这是用于验证真实文字换行的内容。", count: 8))
            .frame(width: 320)
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { measurement.height = $0 }
    }
}
