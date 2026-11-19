import PiMobileCore
import SwiftUI
import UIKit

struct ChatPhotoView: View {
    let attachment: ChatPhotoAttachment
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var thumbnail: CGImage?
    @State private var isDecoding = false
    @State private var showsPreview = false
    @Namespace private var zoomNamespace

    var body: some View {
        Group {
            if let thumbnail {
                Button {
                    PiHaptics.tap()
                    showsPreview = true
                } label: {
                    Image(decorative: thumbnail, scale: 1)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 240, maxHeight: 230, alignment: .trailing)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(Theme.cardStroke.opacity(0.4), lineWidth: 0.5)
                        )
                }
                .buttonStyle(bouncy())
                .matchedTransitionSource(id: "photo-zoom", in: zoomNamespace)
                .accessibilityLabel("图片附件，点按放大预览")
                .transition(.opacity)
            } else if isDecoding {
                PiSkeletonShimmer(cornerRadius: 14)
                    .frame(width: 180, height: 135)
                    .accessibilityLabel("正在加载图片预览")
            } else {
                Label("图片附件 · 预览不可用", systemImage: "photo")
                    .appFont(.callout)
                    .foregroundStyle(.secondary)
                    .padding(10)
                    .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 13))
            }
        }
        .animation(PiMotion.quickFade(reduceMotion), value: thumbnail != nil)
        .fullScreenCover(isPresented: $showsPreview) {
            if let fullImage = decodedFullImage {
                ChatPhotoFullscreenView(image: fullImage)
                    .navigationTransition(.zoom(sourceID: "photo-zoom", in: zoomNamespace))
            }
        }
        .task(id: attachment) {
            thumbnail = nil
            guard attachment.data != nil else {
                isDecoding = false
                return
            }
            isDecoding = true
            let photo = attachment
            let result = await Task.detached(priority: .utility) { photo.thumbnail() }.value
            guard !Task.isCancelled else { return }
            thumbnail = result
            isDecoding = false
        }
    }

    private var decodedFullImage: UIImage? {
        if let data = attachment.data, let image = UIImage(data: data) { return image }
        if let thumbnail { return UIImage(cgImage: thumbnail) }
        return nil
    }
}

private struct ChatPhotoFullscreenView: View {
    let image: UIImage
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()

            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .scaleEffect(scale)
                .gesture(
                    MagnifyGesture()
                        .onChanged { value in
                            scale = min(max(1, lastScale * value.magnification), 4)
                        }
                        .onEnded { _ in
                            lastScale = scale
                        }
                )
                .onTapGesture(count: 2) {
                    PiHaptics.tap()
                    withAnimation(PiMotion.snappy(reduceMotion)) {
                        scale = scale > 1.1 ? 1 : 2.2
                        lastScale = scale
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            PiIconButton(systemName: "xmark", tint: .white) {
                PiHaptics.tap()
                dismiss()
            }
            .accessibilityLabel("关闭图片预览")
            .padding(18)
        }
        .preferredColorScheme(.dark)
    }
}
