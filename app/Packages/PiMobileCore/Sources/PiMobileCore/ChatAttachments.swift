import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A user photo from an inline Pi image block. With no usable bytes the row still represents an attachment.
public struct ChatPhotoAttachment: Equatable, Sendable {
    public let data: Data?

    /// Decode only the first frame, at a size suitable for a chat bubble (including Retina displays).
    public func thumbnail() -> CGImage? {
        guard let data, let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return resizedPhoto(source, maxSide: 768)
    }
}

private func resizedPhoto(_ source: CGImageSource, maxSide: Int) -> CGImage? {
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: maxSide,
        kCGImageSourceShouldCacheImmediately: true,
    ]
    return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
}

public enum ChatAttachments {
    static let maxBytes = 2 * 1024 * 1024
    private static let maxPhotos = 8
    private static let formats = ["image/jpeg": UTType.jpeg, "image/png": .png, "image/gif": .gif, "image/webp": .webP]
    private static let unavailable = ChatPhotoAttachment(data: nil)

    // Pi 1.5 appends these exact, whole lines to the user's prompt with two line breaks.
    // The suffix can survive on old gateways even when the image block itself was discarded.
    private static let hint = #"\[(?:Image: original [0-9]+x[0-9]+, displayed at [0-9]+x[0-9]+\. Multiply coordinates by [0-9]+\.[0-9]+ to map to original image\.|Image converted from image/[A-Za-z0-9.+-]+ to image/[A-Za-z0-9.+-]+\.|Image omitted: could not be (?:converted to a supported inline image format|resized below the inline image size limit)\.)\]"#
    private static let hintSuffix = try! NSRegularExpression(pattern: #"(?:\A|(?:\r?\n){2})"# + hint + #"(?:\r?\n"# + hint + #")*[ \t]*(?:\r?\n)?\z"#)

    static func caption(_ text: String) -> (text: String, hadHint: Bool) {
        guard text.contains("[Image"),
              let match = hintSuffix.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range, in: text) else { return (text, false) }
        return (String(text[..<range.lowerBound]), true)
    }

    /// Encode picked pixels as an upright JPEG within the gateway's per-image limit.
    /// Creating a fresh destination also leaves the original EXIF and GPS metadata behind.
    public static func promptJPEG(from data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let identifier = CGImageSourceGetType(source) as String?, let type = UTType(identifier),
              type.conforms(to: .image), !type.conforms(to: .svg) else { return nil }
        let properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.78,
                                           kCGImageDestinationBackgroundColor: CGColor(gray: 1, alpha: 1)]
        // Start at Pi's display resolution, then scale down only for detailed photos that exceed the byte limit.
        for maxSide in [2000, 1500, 1000] {
            let bytes = NSMutableData()
            guard let image = resizedPhoto(source, maxSide: maxSide),
                  let destination = CGImageDestinationCreateWithData(bytes, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(destination, image, properties as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { return nil }
            if bytes.length <= maxBytes { return bytes as Data }
        }
        return nil
    }

    public static func localPhoto(_ data: Data) -> ChatPhotoAttachment {
        checkedPhoto(data, expectedType: nil)
    }

    private static func checkedPhoto(_ data: Data, expectedType: UTType?) -> ChatPhotoAttachment {
        guard !data.isEmpty, data.count <= maxBytes,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let type = CGImageSourceGetType(source) as String?, formats.values.contains(where: { $0.identifier == type }),
              expectedType == nil || expectedType?.identifier == type,
              let info = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = info[kCGImagePropertyPixelWidth] as? Int, let height = info[kCGImagePropertyPixelHeight] as? Int,
              (1...16_384).contains(width), (1...16_384).contains(height), width * height <= 64_000_000 else { return unavailable }
        return ChatPhotoAttachment(data: data)
    }

    /// The user-role projection for raw Pi content and the gateway's flattened history format.
    public static func project(content: Any?, attachments: Any? = nil) -> (text: String, attachments: [ChatPhotoAttachment]) {
        let blocks = content as? [[String: Any]] ?? []
        let text = content as? String ?? blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined()
        let visible = caption(text)
        let candidates = attachments as? [[String: Any]] ?? blocks
        var photos: [ChatPhotoAttachment] = []
        var remaining = maxBytes
        for block in candidates where block["type"] as? String == "image" {
            var photo = unavailable
            if let mime = block["mimeType"] as? String, let type = formats[mime],
               let encoded = block["data"] as? String, encoded.utf8.count <= ((remaining + 2) / 3) * 4,
               let bytes = Data(base64Encoded: encoded), bytes.count <= remaining {
                photo = checkedPhoto(bytes, expectedType: type)
                remaining -= photo.data?.count ?? 0
            }
            photos.append(photo)
            if photos.count == maxPhotos { break }
        }
        if photos.isEmpty && visible.hadHint { photos.append(unavailable) }
        return (visible.text, photos)
    }
}
