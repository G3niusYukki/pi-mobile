import PiMobileCore
import SwiftUI

struct ChatPhotoView: View {
    let attachment: ChatPhotoAttachment
    @State private var thumbnail: CGImage?

    var body: some View {
        Group {
            if let thumbnail {
                Image(decorative: thumbnail, scale: 1)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 240, maxHeight: 230, alignment: .trailing)
                    .clipShape(RoundedRectangle(cornerRadius: 13))
                    .accessibilityLabel("图片附件")
                    .accessibilityHidden(false)
            } else {
                Label("图片附件 · 预览不可用", systemImage: "photo")
                    .appFont(.callout)
                    .foregroundStyle(.secondary)
                    .padding(10)
                    .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 13))
            }
        }
        .task(id: attachment) {
            thumbnail = nil
            guard attachment.data != nil else { return }
            let photo = attachment
            let result = await Task.detached(priority: .utility) { photo.thumbnail() }.value
            guard !Task.isCancelled else { return }
            thumbnail = result
        }
    }
}
