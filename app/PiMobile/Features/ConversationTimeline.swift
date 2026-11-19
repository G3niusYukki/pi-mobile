import SwiftUI
import Combine

/// Owned by the app, so folding the Duo or leaving a conversation does not discard its viewport.
@MainActor
final class ConversationScrollStore: ObservableObject {
    struct Viewport {
        var offset: CGFloat = 0
        var width: CGFloat = 0
        var anchor: UUID?
        var followsLatest = true
    }

    private var viewports: [String: Viewport] = [:]

    func viewport(for key: String) -> Viewport { viewports[key] ?? Viewport() }
    func save(_ viewport: Viewport, for key: String) { viewports[key] = viewport }
}

/// The viewport follows streaming output only until the reader scrolls away from the bottom.
struct ConversationTimeline<Content: View>: View {
    let storageKey: String
    let messageIDs: [UUID]
    let isLoading: Bool
    var isRunning: Bool = false
    var submittedPromptID: String? = nil
    @ViewBuilder var content: () -> Content

    @EnvironmentObject private var store: ConversationScrollStore
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var position = ScrollPosition(idType: UUID.self)
    @State private var viewport = ConversationScrollStore.Viewport()
    @State private var phase: ScrollPhase = .idle
    @State private var geometry: TimelineGeometry?
    @State private var ready = false
    @State private var needsRestore = true

    private var showsScrollToBottom: Bool {
        ready && !viewport.followsLatest && !messageIDs.isEmpty
    }

    var body: some View {
        ScrollView {
            content()
                .scrollTargetLayout()
        }
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .scrollEdgeEffectStyle(.soft, for: .bottom)
        .scrollPosition($position)
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .onScrollGeometryChange(for: TimelineGeometry.self) { geometry in
            TimelineGeometry(
                offset: max(0, geometry.contentOffset.y + geometry.contentInsets.top),
                height: geometry.contentSize.height,
                width: geometry.containerSize.width,
                viewportHeight: geometry.containerSize.height,
                bottomInset: geometry.contentInsets.bottom
            )
        } action: { old, new in
            geometry = new
            guard ready, scenePhase == .active else { return }
            if old.width != new.width { needsRestore = true }
            if needsRestore {
                restore(in: new)
            } else if phase == .interacting || phase == .decelerating {
                viewport.offset = new.offset
                viewport.width = new.width
                viewport.followsLatest = new.distanceToBottom < 60
                store.save(viewport, for: storageKey)
            } else if viewport.followsLatest,
                      old.height != new.height || old.viewportHeight != new.viewportHeight || old.bottomInset != new.bottomInset {
                position.scrollTo(edge: .bottom)
            } else if !isLoading {
                // Keep the offset produced by an anchor restore, even when a nonanimated
                // scroll does not emit a separate scroll-phase transition.
                viewport.offset = new.offset
                viewport.width = new.width
                store.save(viewport, for: storageKey)
            }
        }
        .onScrollPhaseChange { _, new in
            phase = new
            if new == .idle, ready, !needsRestore, let geometry, scenePhase == .active {
                viewport.offset = geometry.offset
                viewport.width = geometry.width
                store.save(viewport, for: storageKey)
            }
        }
        .onScrollTargetVisibilityChange(idType: UUID.self, threshold: 0.01) { ids in
            guard ready, !needsRestore, phase == .interacting || phase == .decelerating else { return }
            viewport.anchor = messageIDs.first(where: { ids.contains($0) })
            store.save(viewport, for: storageKey)
        }
        .onAppear {
            viewport = store.viewport(for: storageKey)
            ready = true
            needsRestore = true
            if let geometry { restore(in: geometry) }
        }
        .onDisappear {
            if ready { store.save(viewport, for: storageKey) }
        }
        .onChange(of: scenePhase) { _, value in
            if value == .active {
                needsRestore = true
                if let geometry { restore(in: geometry) }
            } else if ready {
                store.save(viewport, for: storageKey)
            }
        }
        .onChange(of: submittedPromptID) { _, id in
            guard id != nil else { return }
            followLatest(animated: false)
        }
        .onChange(of: isLoading) { _, loading in
            guard !loading, ready else { return }
            needsRestore = true
            if let geometry { restore(in: geometry) }
        }
        .overlay(alignment: .bottomTrailing) {
            Group {
                if showsScrollToBottom {
                    Button {
                        PiHaptics.tap()
                        followLatest(animated: true)
                    } label: {
                        HStack(spacing: 6) {
                            if isRunning {
                                StatusDot(color: Theme.ocean, size: 6, pulsing: true)
                            }
                            Image(systemName: "arrow.down")
                                .appFont(.caption.weight(.bold))
                            Text(isRunning ? "实时输出" : "回到最新")
                                .appFont(.caption.weight(.semibold))
                        }
                        .foregroundStyle(Theme.textPrimary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .piGlassCard(radius: 22, tint: Theme.ocean.opacity(0.20), interactive: true)
                    }
                    .buttonStyle(bouncy())
                    .padding(16)
                    .transition(PiMotion.floatingPillTransition)
                }
            }
            .animation(PiMotion.snappy(reduceMotion), value: showsScrollToBottom)
            .animation(PiMotion.quickFade(reduceMotion), value: isRunning)
        }
    }

    private func followLatest(animated: Bool) {
        viewport.followsLatest = true
        store.save(viewport, for: storageKey)
        withAnimation(animated ? PiMotion.smooth(reduceMotion) : nil) {
            position.scrollTo(edge: .bottom)
        }
    }

    private func restore(in geometry: TimelineGeometry) {
        guard ready, !isLoading, geometry.viewportHeight > 0, geometry.height > 0 else { return }
        needsRestore = false
        if viewport.followsLatest {
            position.scrollTo(edge: .bottom)
        } else if abs(viewport.width - geometry.width) > 1,
                  let anchor = viewport.anchor, messageIDs.contains(anchor) {
            // A fold or rotation changes wrapping: restore the visible message instead of an old pixel offset.
            position.scrollTo(id: anchor, anchor: .top)
        } else {
            position.scrollTo(y: viewport.offset)
        }
        viewport.width = geometry.width
    }
}

private struct TimelineGeometry: Equatable {
    let offset: CGFloat
    let height: CGFloat
    let width: CGFloat
    let viewportHeight: CGFloat
    let bottomInset: CGFloat

    var distanceToBottom: CGFloat { max(0, height + bottomInset - viewportHeight - offset) }
}
