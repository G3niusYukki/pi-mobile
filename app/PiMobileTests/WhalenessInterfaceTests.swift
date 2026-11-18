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

    func testTranscriptSeparatesRepliesFromTraceDuringAToolCall() {
        let user = ChatMessage(role: .user, text: "整理路线")
        let pending = ChatMessage(role: .assistant, text: "", streaming: true)
        let tool = ChatMessage(role: .tool, text: "2 条记录")
        let reply = ChatMessage(role: .assistant, text: "建议先去公园。", streaming: true)
        let history = [user, pending, tool]
        XCTAssertEqual(ConversationTab.chat.messages(in: history), [user])
        XCTAssertEqual(ConversationTab.trace.messages(in: history), [tool])
        XCTAssertTrue(ConversationTab.waitsForReply(in: history, connection: .running))
        XCTAssertFalse(ConversationTab.waitsForReply(in: history, connection: .paired))
        XCTAssertEqual(ConversationTab.chat.messages(in: history + [reply]), [user, reply])
        XCTAssertFalse(ConversationTab.waitsForReply(in: history + [reply], connection: .running))
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
        try await snapshot("workspace-narrow", size: narrow, style: .light, model: model, store: store) {
            SessionsPane(onSettings: {})
        }
        try await snapshot("workspace-wide", size: wide, style: .dark, model: model, store: store) {
            SessionsPane(onSettings: {})
        }
        model.clearError()
        XCTAssertEqual(ConversationTab.chat.messages(in: model.messages).count, 2, "Rendered conversation must contain the supplied history")
        try await snapshot("conversation-light", size: narrow, style: .light, model: model, store: store) {
            ConversationScreen(onSettings: {})
        }
        try await snapshot("conversation-dark-wide", size: wide, style: .dark, model: model, store: store) {
            ConversationScreen(onSettings: {})
        }
        model.messages.append(ChatMessage(role: .user, text: "如果下雨，有室内的备选吗？"))
        model.connection = .running
        try await snapshot("conversation-waiting", size: narrow, style: .dark, model: model, store: store) {
            ConversationScreen(onSettings: {})
        }
        model.connection = .paired
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
        model.connection = .paired
        model.selectedSessionPath = "/preview/pi-session.jsonl"
        model.selectedSessionTitle = "周六骑行路线"
        model.models = [
            ModelOption(provider: "OpenAI", modelId: "gpt-6-astra", displayName: "GPT-6 Astra"),
            ModelOption(provider: "OpenAI", modelId: "gpt-5.4", displayName: "GPT-5.4"),
            ModelOption(provider: "Anthropic", modelId: "claude-opus-4-7", displayName: "Claude Opus 4.7"),
        ]
        model.selectedModel = model.models[0].id
        let now = Date().timeIntervalSince1970 * 1_000
        model.sessions = [
            ["path": "/preview/pi-session.jsonl", "title": "周六骑行路线", "cwd": "/projects/weekend", "summary": "沿河骑到植物园，午饭前回到车站。", "mtime": now - 600_000],
            ["path": "/preview/session-two.jsonl", "title": "野餐采购清单", "cwd": "/projects/weekend", "summary": "按四人份整理食材和饮料。", "mtime": now - 7_200_000],
            ["path": "/preview/session-three.jsonl", "title": "调整文章目录", "cwd": "/projects/field-notes", "summary": "把春季观察单独整理成一章。", "mtime": now - 86_400_000],
        ]
        model.messages = [
            ChatMessage(role: .user, text: "周六上午从车站出发，想沿河骑一圈。怎么安排比较从容？"),
            ChatMessage(role: .tool, text: "找到两段沿河路线。", toolTitle: "读取路线笔记"),
            ChatMessage(role: .assistant, text: "建议走 **车站 → 河堤 → 植物园**，回程沿原路骑。\n\n九点从车站出发，到植物园大约四十分钟。可以在河边停下来吃点东西，十点半折返。\n\n如果风大，就在老桥掉头。这样还能留出时间喝杯咖啡。"),
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
