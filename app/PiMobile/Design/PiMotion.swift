import SwiftUI
import UIKit

// MARK: - 统一物理动效曲线（全部自动尊重 Reduce Motion）

enum PiMotion {
    /// 快速跟手回弹：按钮变形、浮层开关、状态切换
    static func snappy(_ reduceMotion: Bool) -> Animation? {
        reduceMotion ? .easeOut(duration: 0.12) : .spring(duration: 0.28, bounce: 0.16)
    }

    /// 顺滑阻尼：工具行折叠展开、横幅进出、回底滚动
    static func smooth(_ reduceMotion: Bool) -> Animation? {
        reduceMotion ? .easeOut(duration: 0.15) : .spring(duration: 0.36, bounce: 0.06)
    }

    /// 柔和无过冲：卡片浮现、空白页入场
    static func gentle(_ reduceMotion: Bool) -> Animation? {
        reduceMotion ? .easeOut(duration: 0.16) : .spring(duration: 0.44, bounce: 0.0)
    }

    /// 极轻淡变：文本/图标微变化
    static func quickFade(_ reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeOut(duration: 0.16)
    }

    static var bannerTransition: AnyTransition {
        .asymmetric(
            insertion: .move(edge: .top).combined(with: .opacity),
            removal: .move(edge: .top).combined(with: .opacity)
        )
    }

    static var floatingPillTransition: AnyTransition {
        .move(edge: .bottom)
            .combined(with: .scale(scale: 0.84))
            .combined(with: .opacity)
    }

    static var cardRiseTransition: AnyTransition {
        .asymmetric(
            insertion: .move(edge: .bottom).combined(with: .scale(scale: 0.96)).combined(with: .opacity),
            removal: .scale(scale: 0.96).combined(with: .opacity)
        )
    }

    static var controlPopTransition: AnyTransition {
        .scale(scale: 0.82).combined(with: .opacity)
    }

    static var disclosureTransition: AnyTransition {
        .opacity.combined(with: .move(edge: .top))
    }
}

// MARK: - 统一触觉编排

@MainActor
enum PiHaptics {
    static func send() {
        let generator = UIImpactFeedbackGenerator(style: .soft)
        generator.impactOccurred(intensity: 0.75)
    }

    static func stop() {
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.impactOccurred(intensity: 0.85)
    }

    static func tap() {
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.impactOccurred(intensity: 0.65)
    }

    static func selection() {
        UISelectionFeedbackGenerator().selectionChanged()
    }

    static func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    static func warning() {
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }
}

// MARK: - Claude / Codex 风格扫光文字

struct PiShimmerText: View {
    let text: String
    var font: AppFont = .footnote.weight(.medium)
    var baseColor: Color = Theme.textSecondary
    var highlightColor: Color = Theme.textPrimary

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = -1

    var body: some View {
        Text(text)
            .appFont(font)
            .foregroundStyle(baseColor)
            .overlay {
                if !reduceMotion {
                    GeometryReader { geo in
                        let width = max(geo.size.width, 60)
                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: 0.0),
                                .init(color: highlightColor.opacity(0.85), location: 0.5),
                                .init(color: .clear, location: 1.0),
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: width * 0.65)
                        .offset(x: phase * width * 1.65)
                    }
                    .mask(
                        Text(text)
                            .appFont(font)
                    )
                    .allowsHitTesting(false)
                }
            }
            .onAppear {
                guard !reduceMotion else { return }
                phase = -1
                withAnimation(.linear(duration: 1.75).repeatForever(autoreverses: false)) {
                    phase = 1
                }
            }
    }
}

// MARK: - 呼吸思考态指示器（替代裸 ProgressView）

struct PiThinkingIndicator: View {
    let label: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathe = false

    var body: some View {
        HStack(spacing: 9) {
            ZStack {
                if !reduceMotion {
                    Circle()
                        .fill(Theme.ocean.opacity(0.24))
                        .frame(width: 16, height: 16)
                        .scaleEffect(breathe ? 1.28 : 0.72)
                        .opacity(breathe ? 0.15 : 0.65)
                }
                Circle()
                    .fill(Theme.ocean)
                    .frame(width: 7, height: 7)
                    .scaleEffect(!reduceMotion && breathe ? 1.12 : 0.9)
            }
            .frame(width: 16, height: 16)
            .accessibilityHidden(true)

            PiShimmerText(text: label, font: .footnote.weight(.medium))
                .id(label)
                .transition(.opacity)
        }
        .animation(PiMotion.quickFade(reduceMotion), value: label)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.15).repeatForever(autoreverses: true)) {
                breathe = true
            }
        }
    }
}

// MARK: - 流式输出呼吸光标（替代 Markdown 尾部转圈）

struct PiStreamingCursor: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var glowing = false

    var body: some View {
        HStack(spacing: 5) {
            Capsule(style: .continuous)
                .fill(Theme.ocean)
                .frame(width: 6, height: 13)
                .scaleEffect(y: !reduceMotion && glowing ? 1.0 : 0.78)
                .opacity(!reduceMotion && glowing ? 1.0 : 0.42)
                .shadow(color: Theme.ocean.opacity(glowing ? 0.45 : 0.08), radius: 4)
        }
        .accessibilityLabel("Pi 正在回复")
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.75).repeatForever(autoreverses: true)) {
                glowing = true
            }
        }
    }
}

// MARK: - 柔和骨架扫光（图片解码等过渡态）

struct PiSkeletonShimmer: View {
    var cornerRadius: CGFloat = 13
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var offset: CGFloat = -1

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Theme.cardFill)
            .overlay {
                if !reduceMotion {
                    GeometryReader { geo in
                        LinearGradient(
                            colors: [.clear, Color.primary.opacity(0.08), .clear],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: max(geo.size.width * 0.7, 60))
                        .offset(x: offset * max(geo.size.width * 1.7, 120))
                    }
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                }
            }
            .onAppear {
                guard !reduceMotion else { return }
                offset = -1
                withAnimation(.linear(duration: 1.35).repeatForever(autoreverses: false)) {
                    offset = 1
                }
            }
    }
}
