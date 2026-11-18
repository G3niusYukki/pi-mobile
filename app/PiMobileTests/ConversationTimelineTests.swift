import XCTest
import SwiftUI
@testable import PiMobile

/// Exercise the real SwiftUI scroll view in a hosted window, including restoration and content reflow.
@MainActor
final class ConversationTimelineTests: XCTestCase {
    private var window: UIWindow?
    private var previousWindow: UIWindow?

    override func tearDown() {
        window?.isHidden = true
        window = nil
        previousWindow?.makeKey()
        previousWindow = nil
        super.tearDown()
    }

    func testFirstOpenAndGrowingReplyStayAtBottom() async throws {
        let fixture = TimelineFixture()
        let store = ConversationScrollStore()
        let scroll = try await host(fixture, store: store)
        try await eventually { self.distanceToBottom(scroll) < 5 }
        let initialHeight = scroll.contentSize.height
        fixture.extraHeight = 1200
        try await eventually { scroll.contentSize.height > initialHeight + 1000 }
        try await eventually { self.distanceToBottom(scroll) < 5 }
    }

    func testReadingOffsetSurvivesStreamWakeAndViewRecreation() async throws {
        let fixture = TimelineFixture()
        let store = ConversationScrollStore()
        store.save(.init(offset: 900, width: 390, anchor: fixture.ids[10], followsLatest: false), for: "session/chat")
        let scroll = try await host(fixture, store: store)
        try await eventually { abs(self.offset(scroll) - 900) < 5 }
        let initialHeight = scroll.contentSize.height
        fixture.ids.append(contentsOf: (0..<15).map { _ in UUID() })
        try await eventually { scroll.contentSize.height > initialHeight + 1000 }
        XCTAssertEqual(offset(scroll), 900, accuracy: 5, "A new reply must not move a reader looking at older messages")
        fixture.scene = .background
        await nextFrames()
        fixture.scene = .active
        await nextFrames()
        XCTAssertEqual(offset(scroll), 900, accuracy: 5, "Screen wake must preserve the reading offset")
        fixture.identity += 1
        try await eventually {
            guard let restored = self.window.flatMap({ self.findScrollView(in: $0) }) else { return false }
            return restored !== scroll && abs(self.offset(restored) - 900) < 5
        }
    }

    func testKeyboardResizeKeepsFollowingLatest() async throws {
        let fixture = TimelineFixture()
        let scroll = try await host(fixture, store: ConversationScrollStore())
        try await eventually { self.distanceToBottom(scroll) < 5 }
        fixture.height = 300
        try await eventually { abs(scroll.bounds.height - 300) < 1 }
        try await eventually { self.distanceToBottom(scroll) < 5 }
        fixture.height = 600
        try await eventually { abs(scroll.bounds.height - 600) < 1 }
        try await eventually { self.distanceToBottom(scroll) < 5 }
    }

    func testReadingAnchorSurvivesWidthChangeWithoutRecreatingView() async throws {
        let fixture = TimelineFixture()
        let store = ConversationScrollStore()
        store.save(.init(offset: 900, width: 390, anchor: fixture.ids[10], followsLatest: false), for: "session/chat")
        _ = try await host(fixture, store: store)
        try await eventually { abs(fixture.frames[fixture.ids[10]]?.minY ?? -9999) < 5 }
        fixture.width = 700
        fixture.wraps = true
        try await eventually { abs(fixture.frames[fixture.ids[10]]?.minY ?? -9999) < 5 }
        // Wait beyond the first update so a stale pre-reflow frame cannot satisfy the assertion.
        await nextFrames()
        XCTAssertEqual(try XCTUnwrap(fixture.frames[fixture.ids[10]]).minY, 0, accuracy: 5)
    }

    func testKeyboardResizePreservesOlderReadingOffset() async throws {
        let fixture = TimelineFixture()
        let store = ConversationScrollStore()
        store.save(.init(offset: 900, width: 390, anchor: fixture.ids[10], followsLatest: false), for: "session/chat")
        let scroll = try await host(fixture, store: store)
        try await eventually { abs(self.offset(scroll) - 900) < 5 }
        fixture.height = 300
        try await eventually { abs(scroll.bounds.height - 300) < 1 }
        await nextFrames()
        XCTAssertEqual(offset(scroll), 900, accuracy: 5)
        fixture.height = 600
        try await eventually { abs(scroll.bounds.height - 600) < 1 }
        await nextFrames()
        XCTAssertEqual(offset(scroll), 900, accuracy: 5)
    }

    func testHistoryLoadingDefersReadingPositionRestoration() async throws {
        let fixture = TimelineFixture()
        fixture.loading = true
        let store = ConversationScrollStore()
        store.save(.init(offset: 1800, width: 390, anchor: fixture.ids[20], followsLatest: false), for: "session/chat")
        let scroll = try await host(fixture, store: store)
        fixture.loading = false
        try await eventually { abs(self.offset(scroll) - 1800) < 5 }
    }

    private func host(_ fixture: TimelineFixture, store: ConversationScrollStore) async throws -> UIScrollView {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        previousWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: TimelineFixtureView(fixture: fixture).environmentObject(store))
        window.makeKeyAndVisible()
        self.window = window
        try await eventually {
            guard let scroll = self.findScrollView(in: window) else { return false }
            return scroll.contentSize.height > 2000 && scroll.bounds.height > 0
        }
        return try XCTUnwrap(findScrollView(in: window))
    }

    private func findScrollView(in view: UIView) -> UIScrollView? {
        if let scroll = view as? UIScrollView { return scroll }
        return view.subviews.lazy.compactMap { self.findScrollView(in: $0) }.first
    }

    private func offset(_ scroll: UIScrollView) -> CGFloat {
        scroll.contentOffset.y + scroll.adjustedContentInset.top
    }

    private func distanceToBottom(_ scroll: UIScrollView) -> CGFloat {
        abs(scroll.contentSize.height + scroll.adjustedContentInset.bottom - scroll.bounds.height - scroll.contentOffset.y)
    }

    private func eventually(file: StaticString = #filePath, line: UInt = #line, _ condition: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(30))
        }
        XCTFail("Scroll view did not reach the expected visible position", file: file, line: line)
        throw TimelineTestError.timedOut
    }

    private func nextFrames() async {
        try? await Task.sleep(for: .milliseconds(150))
    }
}

private enum TimelineTestError: Error { case timedOut }

@MainActor
private final class TimelineFixture: ObservableObject {
    @Published var ids = (0..<80).map { _ in UUID() }
    @Published var extraHeight: CGFloat = 0
    @Published var height: CGFloat = 600
    @Published var width: CGFloat = 390
    @Published var wraps = false
    var frames: [UUID: CGRect] = [:]
    @Published var scene: ScenePhase = .active
    @Published var loading = false
    @Published var identity = 0
}

private struct TimelineFixtureView: View {
    @ObservedObject var fixture: TimelineFixture

    var body: some View {
        ConversationTimeline(storageKey: "session/chat", messageIDs: fixture.ids, isLoading: fixture.loading) {
            LazyVStack(spacing: 0) {
                ForEach(Array(fixture.ids.enumerated()), id: \.element) { index, id in
                    Group {
                        if fixture.wraps {
                            Text("Message \(index) " + String(repeating: "Reading position should follow this message as the Duo changes width. ", count: 18))
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            Text("Message \(index)")
                                .frame(height: 90 + (index == fixture.ids.count - 1 ? fixture.extraHeight : 0))
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .id(id)
                    .onGeometryChange(for: CGRect.self) { proxy in
                        proxy.frame(in: .named("fixture-scroll"))
                    } action: { frame in
                        fixture.frames[id] = frame
                    }
                }
            }
        }
        .frame(width: fixture.width, height: fixture.height)
        .coordinateSpace(name: "fixture-scroll")
        .environment(\.scenePhase, fixture.scene)
        .id(fixture.identity)
    }
}
