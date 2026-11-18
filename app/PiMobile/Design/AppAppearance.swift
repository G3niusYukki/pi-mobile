import SwiftUI
import UIKit

/// Local preferences, independent of the paired gateway and current session.
enum PiInterfaceStyle: String, CaseIterable, Identifiable {
    case system, light, dark

    static let key = "appearance.interfaceStyle"
    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

// Typography follows Whaleness, including Dynamic Type and an independent app multiplier.
enum AppFontScale {
    static let key = "appearance.fontScale"
    static let followsSystemKey = "appearance.fontFollowsSystem"

    static func effective(_ value: Double, followsSystem: Bool) -> Double {
        followsSystem ? 1 : normalized(value)
    }

    static func normalized(_ value: Double) -> Double {
        value.isFinite ? min(1.5, max(0.8, value)) : 1
    }

    static var current: CGFloat {
        let value = UserDefaults.standard.object(forKey: key) as? Double ?? 1
        return CGFloat(effective(value, followsSystem: UserDefaults.standard.bool(forKey: followsSystemKey)))
    }
}

/// One description for semantic text, fixed-size text and standalone UIKit hosts.
struct AppFont {
    private var style: UIFont.TextStyle = .body
    private var size: CGFloat?
    private var fontWeight: Font.Weight?
    private var design: Font.Design = .default
    private var usesMonospacedDigits = false

    static let largeTitle = system(.largeTitle)
    static let title = system(.title)
    static let title2 = system(.title2)
    static let title3 = system(.title3)
    static let headline = system(.headline)
    static let subheadline = system(.subheadline)
    static let body = system(.body)
    static let callout = system(.callout)
    static let footnote = system(.footnote)
    static let caption = system(.caption)
    static let caption2 = system(.caption2)

    static func system(size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> AppFont {
        AppFont(size: size, fontWeight: weight, design: design)
    }

    static func system(_ style: Font.TextStyle, design: Font.Design = .default) -> AppFont {
        let uiStyle: UIFont.TextStyle
        switch style {
        case .largeTitle: uiStyle = .largeTitle
        case .title: uiStyle = .title1
        case .title2: uiStyle = .title2
        case .title3: uiStyle = .title3
        case .headline: uiStyle = .headline
        case .subheadline: uiStyle = .subheadline
        case .callout: uiStyle = .callout
        case .footnote: uiStyle = .footnote
        case .caption: uiStyle = .caption1
        case .caption2: uiStyle = .caption2
        default: uiStyle = .body
        }
        return AppFont(style: uiStyle, design: design)
    }

    func weight(_ value: Font.Weight) -> AppFont {
        var copy = self
        copy.fontWeight = value
        return copy
    }

    func bold() -> AppFont { weight(.bold) }

    func monospaced() -> AppFont {
        var copy = self
        copy.design = .monospaced
        return copy
    }

    func monospacedDigit() -> AppFont {
        var copy = self
        copy.usesMonospacedDigits = true
        return copy
    }

    func resolved(scale: CGFloat) -> Font {
        let base = size.map { UIFontMetrics.default.scaledValue(for: $0) }
            ?? UIFont.preferredFont(forTextStyle: style).pointSize
        var font = Font.system(
            size: base * scale,
            weight: fontWeight ?? (style == .headline ? .semibold : .regular),
            design: design
        )
        if usesMonospacedDigits { font = font.monospacedDigit() }
        return font
    }
}

enum SettingsTypography {
    static let title = AppFont.body.weight(.semibold)
    static let item = AppFont.body
    static let description = AppFont.caption
    static let section = description
}

private struct AppFontModifier: ViewModifier {
    @AppStorage(AppFontScale.key) private var scale = 1.0
    @AppStorage(AppFontScale.followsSystemKey) private var followsSystem = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let value: AppFont

    func body(content: Content) -> some View {
        content.font(value.resolved(scale: CGFloat(AppFontScale.effective(scale, followsSystem: followsSystem))))
    }
}

struct AppFontScope: ViewModifier {
    @AppStorage(AppFontScale.key) private var scale = 1.0
    @AppStorage(AppFontScale.followsSystemKey) private var followsSystem = false
    @Environment(\.dynamicTypeSize) private var systemSize

    func body(content: Content) -> some View {
        // Native controls use the closest Dynamic Type size; app text keeps the exact multiplier.
        let scale = AppFontScale.effective(scale, followsSystem: followsSystem)
        let target = UIFont.preferredFont(forTextStyle: .body).pointSize * scale
        let closest = DynamicTypeSize.allCases.min { lhs, rhs in
            abs(bodySize(lhs) - target) < abs(bodySize(rhs) - target)
        } ?? systemSize
        content
            .font(AppFont.body.resolved(scale: CGFloat(scale)))
            .dynamicTypeSize(closest)
    }

    private func bodySize(_ size: DynamicTypeSize) -> CGFloat {
        let categories: [UIContentSizeCategory] = [
            .extraSmall, .small, .medium, .large, .extraLarge,
            .extraExtraLarge, .extraExtraExtraLarge, .accessibilityMedium,
            .accessibilityLarge, .accessibilityExtraLarge,
            .accessibilityExtraExtraLarge, .accessibilityExtraExtraExtraLarge,
        ]
        let index = DynamicTypeSize.allCases.firstIndex(of: size) ?? 3
        return UIFont.preferredFont(
            forTextStyle: .body,
            compatibleWith: UITraitCollection(preferredContentSizeCategory: categories[index])
        ).pointSize
    }
}

extension View {
    func appFont(_ value: AppFont) -> some View {
        modifier(AppFontModifier(value: value))
    }
}

extension UIFont {
    static func appPreferredFont(forTextStyle style: UIFont.TextStyle) -> UIFont {
        let font = preferredFont(forTextStyle: style)
        return font.withSize(font.pointSize * AppFontScale.current)
    }

    static func appMonospacedFont(ofSize size: CGFloat, weight: UIFont.Weight) -> UIFont {
        monospacedSystemFont(
            ofSize: UIFontMetrics.default.scaledValue(for: size) * AppFontScale.current,
            weight: weight
        )
    }
}
