import SwiftUI
import PiMobileCore

// MARK: - 视觉语言（参考 dsh-mobile 的 Deep Ocean）

enum Theme {
    static let navy = Color(red: 0.027, green: 0.094, blue: 0.169)
    static let navyDeep = Color(red: 0.012, green: 0.039, blue: 0.078)
    static let navyRaised = Color(red: 0.05, green: 0.14, blue: 0.25)
    static let ocean = Color(red: 0.18, green: 0.42, blue: 0.90)
    static let oceanDeep = Color(red: 0.10, green: 0.28, blue: 0.70)
    static let mist = Color(red: 0.75, green: 0.84, blue: 1)
    static let success = Color(red: 0.18, green: 0.72, blue: 0.36)
    static let amber = Color(red: 1.0, green: 0.68, blue: 0.12)
    static let coral = Color(red: 0.93, green: 0.33, blue: 0.30)
    static let purple = Color(red: 0.48, green: 0.33, blue: 0.78)

    static let bgSolid = navyDeep
    static let sidebarBG = navyDeep
    static let inputFill = Color.primary.opacity(0.06)

    static let cardFill = Color.primary.opacity(0.055)
    static let cardFillStrong = Color.primary.opacity(0.10)
    static let cardStroke = Color.primary.opacity(0.12)

    static let accentFill = ocean
    static let onAccent = Color.white

    static let azure = ocean
    static let mint = success

    static let textPrimary = Color.primary
    static let textSecondary = Color.secondary
    static let textTertiary = Color.primary.opacity(0.42)

    static func background() -> some View { PiBackground() }
}

/// 深海军蓝 + 极细技术网格 + 顶部冷光，避开折痕区域。
struct PiBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Theme.navy, Theme.navyDeep, Color.black],
                startPoint: .top,
                endPoint: .bottom
            )
            PiTechnicalGrid()
            RadialGradient(
                colors: [Theme.ocean.opacity(0.24), .clear],
                center: .init(x: 0.72, y: 0.12),
                startRadius: 20,
                endRadius: 520
            )
            .blendMode(.screen)
            LinearGradient(
                colors: [.clear, Theme.navyDeep.opacity(0.35), Color.black.opacity(0.55)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct PiTechnicalGrid: View {
    var body: some View {
        Canvas { context, size in
            let spacing: CGFloat = 42
            var path = Path()
            for x in stride(from: -spacing, through: size.width + spacing, by: spacing) {
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
            }
            for y in stride(from: -spacing, through: size.height + spacing, by: spacing) {
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
            }
            context.stroke(path, with: .color(.white.opacity(0.045)), lineWidth: 0.6)

            let columns = Int(ceil(size.width / spacing)) + 1
            let rows = Int(ceil(size.height / spacing)) + 1
            for row in 0..<rows {
                for column in 0..<columns where (row * 11 + column * 7) % 13 == 0 {
                    let point = CGPoint(x: CGFloat(column) * spacing, y: CGFloat(row) * spacing)
                    context.fill(
                        Path(CGRect(x: point.x - 1, y: point.y - 1, width: 2, height: 2)),
                        with: .color(.white.opacity(0.08))
                    )
                }
            }
        }
        .mask(
            LinearGradient(
                stops: [
                    .init(color: .white.opacity(0.8), location: 0),
                    .init(color: .white, location: 0.55),
                    .init(color: .clear, location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }
}

// MARK: - 液态玻璃

struct GlassSurface: ViewModifier {
    let radius: CGFloat
    let tint: Color?
    let clear: Bool

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            if clear {
                if let tint {
                    content.glassEffect(.clear.tint(tint), in: .rect(cornerRadius: radius))
                } else {
                    content.glassEffect(.clear, in: .rect(cornerRadius: radius))
                }
            } else {
                if let tint {
                    content.glassEffect(.regular.tint(tint), in: .rect(cornerRadius: radius))
                } else {
                    content.glassEffect(.regular, in: .rect(cornerRadius: radius))
                }
            }
        } else {
            content
                .background(
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(.ultraThinMaterial)
                        .overlay(
                            RoundedRectangle(cornerRadius: radius, style: .continuous)
                                .fill(tint ?? .clear)
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(.white.opacity(0.18), lineWidth: 0.8)
                )
                .shadow(color: Theme.navy.opacity(0.35), radius: 16, y: 8)
        }
    }
}

extension View {
    func piGlassCard(radius: CGFloat = 20, tint: Color? = nil, clear: Bool = false) -> some View {
        modifier(GlassSurface(radius: radius, tint: tint, clear: clear))
    }
}

// MARK: - 品牌标志

struct PiMark: View {
    var size: CGFloat = 34
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                .fill(Theme.accentFill)
            Text("π")
                .font(.system(size: size * 0.60, weight: .black))
                .foregroundStyle(Theme.onAccent)
                .offset(y: -size * 0.02)
        }
        .frame(width: size, height: size)
    }
}

struct PiWordmark: View {
    var body: some View {
        HStack(spacing: 8) {
            PiMark(size: 30)
            Text("Pi")
                .appFont(.title3.bold())
                .foregroundStyle(Theme.textPrimary)
            Text("MOBILE")
                .appFont(.caption2.bold())
                .foregroundStyle(Theme.textPrimary.opacity(0.85))
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Capsule().fill(.white.opacity(0.14)))
        }
    }
}

// MARK: - 通用控件

struct PiStatusPill: View {
    let state: ConnectionState

    private var color: Color {
        switch state {
        case .paired: return Theme.success
        case .running: return Theme.amber
        case .connecting: return Theme.mist
        case .error: return Theme.coral
        case .idle: return .gray
        }
    }

    private var text: String {
        switch state {
        case .idle: return "未连接"
        case .connecting: return "连接中…"
        case .paired: return "已连接"
        case .running: return "Pi 工作中"
        case .error: return "连接异常"
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
                .shadow(color: color.opacity(0.7), radius: 4)
            Text(text)
                .appFont(.caption.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .piGlassCard(radius: 14)
    }
}

struct PiIconButton: View {
    let systemName: String
    var tint: Color = Theme.textPrimary
    var size: CGFloat = 44
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .appFont(.system(size: 16, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: size, height: size)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
    }
}

struct PiSegmentedControl<Selection: Hashable>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var selection: Selection
    let options: [(Selection, String)]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(options, id: \.0) { option in
                let value = option.0
                let title = option.1
                Button {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) { selection = value }
                } label: {
                    Text(title)
                        .appFont(.subheadline.weight(.semibold))
                        .foregroundStyle(selection == value ? .white : Theme.textSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(
                            Capsule().fill(selection == value ? Theme.ocean.opacity(0.72) : .clear)
                        )
                }
                .buttonStyle(bouncy())
                .accessibilityAddTraits(selection == value ? .isSelected : [])
            }
        }
        .padding(4)
        .piGlassCard(radius: 18)
    }
}

struct PiSearchField: View {
    @Binding var text: String
    var placeholder: String = "搜索会话"

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Theme.textTertiary)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .foregroundStyle(Theme.textPrimary)
                .autocapitalization(.none)
                .disableAutocorrection(true)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Theme.textTertiary)
                }
                .buttonStyle(bouncy())
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .piGlassCard(radius: 16)
    }
}

// MARK: - 旧组件兼容层（Markdown / 主题仍会用到）

/// 状态点（带呼吸光晕）
struct StatusDot: View {
    var color: Color
    var pulsing: Bool = false
    @State private var phase: CGFloat = 0

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .overlay(
                Circle()
                    .stroke(color.opacity(0.5), lineWidth: 1)
                    .scaleEffect(1 + phase * 2.2)
                    .opacity(pulsing ? 1 - phase : 0)
            )
            .onAppear {
                guard pulsing else { return }
                withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) {
                    phase = 1
                }
            }
    }
}

struct GlassCard<Content: View>: View {
    var padding: CGFloat = 18
    var cornerRadius: CGFloat = 22
    var strong: Bool = false
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(padding)
            .piGlassCard(radius: cornerRadius, tint: strong ? Theme.cardFillStrong : nil)
    }
}

struct CircleIconButton: View {
    var systemName: String
    var size: CGFloat = 44
    var tint: Color = Theme.textPrimary
    var action: () -> Void

    var body: some View {
        PiIconButton(systemName: systemName, tint: tint, size: size, action: action)
    }
}

struct PillBadge: View {
    var text: String
    var tint: Color = Theme.textSecondary
    var filled: Bool = false

    var body: some View {
        Text(text)
            .appFont(.system(size: 11, weight: .semibold))
            .foregroundStyle(filled ? Theme.onAccent : tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(filled ? tint : Theme.cardFill))
            .overlay(filled ? nil : Capsule().strokeBorder(Theme.cardStroke, lineWidth: 1))
    }
}

struct PrimaryActionButton: View {
    var title: String
    var systemName: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemName)
                    .appFont(.system(size: 16, weight: .semibold))
                Text(title)
                    .appFont(.system(size: 17, weight: .semibold))
            }
            .foregroundStyle(Theme.textPrimary)
            .frame(maxWidth: .infinity)
            .frame(height: 54)
            .piGlassCard(radius: 18, tint: Theme.ocean.opacity(0.18))
        }
        .buttonStyle(bouncy())
    }
}

struct bouncy: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.72 : 1)
            .animation(reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.72), value: configuration.isPressed)
    }
}

extension View {
    var bouncyButtonStyle: some View { buttonStyle(bouncy()) }
}
