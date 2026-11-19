import SwiftUI
import UIKit

struct PiCopyButton: View {
    let text: String
    var title = "复制"
    var compact = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var copied = false

    var body: some View {
        Button {
            UIPasteboard.general.string = text
            PiHaptics.success()
            withAnimation(PiMotion.snappy(reduceMotion)) {
                copied = true
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .contentTransition(.symbolEffect(.replace.downUp))
                if !compact || copied {
                    Text(copied ? "已复制" : title)
                        .transition(.opacity.combined(with: .scale(scale: 0.92)))
                }
            }
            .appFont(.caption.weight(copied ? .semibold : .regular))
            .foregroundStyle(copied ? Theme.success : Theme.textSecondary)
            .padding(.horizontal, compact ? 8 : 8)
            .frame(minWidth: compact ? 36 : 44, minHeight: compact ? 34 : 44)
        }
        .buttonStyle(bouncy())
        .disabled(text.isEmpty)
        .accessibilityLabel(copied ? "已复制" : title)
        .animation(PiMotion.snappy(reduceMotion), value: copied)
        .task(id: copied) {
            guard copied else { return }
            do {
                try await Task.sleep(for: .seconds(1.5))
                withAnimation(PiMotion.quickFade(reduceMotion)) {
                    copied = false
                }
            } catch { /* A disappearing message cancels its feedback timer. */ }
        }
    }
}
