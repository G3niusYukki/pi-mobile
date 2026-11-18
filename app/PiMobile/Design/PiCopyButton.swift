import SwiftUI
import UIKit

struct PiCopyButton: View {
    let text: String
    var title = "复制"
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var copied = false

    var body: some View {
        Button {
            UIPasteboard.general.string = text
            copied = true
        } label: {
            Label(copied ? "已复制" : title, systemImage: copied ? "checkmark" : "doc.on.doc")
                .appFont(.caption)
                .foregroundStyle(copied ? Theme.success : Theme.textSecondary)
                .padding(.horizontal, 8)
                .frame(minWidth: 44, minHeight: 44)
        }
        .buttonStyle(bouncy())
        .disabled(text.isEmpty)
        .accessibilityLabel(copied ? "已复制" : title)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: copied)
        .task(id: copied) {
            guard copied else { return }
            do {
                try await Task.sleep(for: .seconds(1.5))
                copied = false
            } catch { /* A disappearing message cancels its feedback timer. */ }
        }
    }
}
