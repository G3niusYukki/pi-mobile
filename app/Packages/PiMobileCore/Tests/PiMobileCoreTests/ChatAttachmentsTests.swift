import XCTest
import ImageIO
import UniformTypeIdentifiers
import PiMobileCore

final class ChatAttachmentsTests: XCTestCase {
    private let hint = "[Image: original 2853x2007, displayed at 2000x1407. Multiply coordinates by 1.43 to map to original image.]"
    private let pixel = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGM4UCDxHwAFhAJIWblWNgAAAABJRU5ErkJggg=="

    func testUserPhotoSurvivesContentProjectionWithExactCaptionAndUsableThumbnail() throws {
        let caption = "  保留换行。  \n"
        let image = ["type": "image", "mimeType": "image/png", "data": pixel]
        let projected = ChatAttachments.project(content: [["type": "text", "text": "\(caption)\n\n[Image converted from image/heic to image/png.]\n\(hint)"], image])
        XCTAssertEqual(projected.text, caption)
        let attachment = try XCTUnwrap(projected.attachments.first)
        XCTAssertEqual(projected.attachments.count, 1)
        let bytes = try XCTUnwrap(Data(base64Encoded: pixel))
        XCTAssertEqual(attachment.data, bytes)
        XCTAssertEqual(attachment, ChatAttachments.localPhoto(bytes))
        XCTAssertEqual(attachment.thumbnail()?.width, 1)
    }

    func testHistoryHandlesBinaryPhotoOnlyAndMarkerOnlyLegacyRows() throws {
        let legacy = ChatAttachments.project(content: "\n\n\(hint)")
        XCTAssertEqual(legacy.text, "")
        XCTAssertEqual(legacy.attachments.count, 1)
        XCTAssertNil(legacy.attachments.first?.data)
        let history = ChatAttachments.project(content: "", attachments: [["type": "image", "mimeType": "image/png", "data": pixel]])
        XCTAssertEqual(history.attachments.count, 1)
        XCTAssertNotNil(history.attachments.first?.thumbnail())
    }

    func testPickedCameraPhotoFitsThePromptLimitAndPreservesRotationWithoutLocation() throws {
        let width = 2600, height = 2400
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 4 * width, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let pixels = try XCTUnwrap(context.data).bindMemory(to: UInt32.self, capacity: width * height)
        var noise: UInt32 = 1
        for i in 0..<(width * height) {
            noise = noise &* 1_664_525 &+ 1_013_904_223
            pixels[i] = noise
        }
        let input = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(input, UTType.jpeg.identifier as CFString, 1, nil))
        let properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.95,
            kCGImagePropertyOrientation: 6,
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 1, kCGImagePropertyGPSLatitudeRef: "N"],
        ]
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        XCTAssertGreaterThan(input.length, 2 * 1024 * 1024)
        let fixture = try XCTUnwrap(CGImageSourceCreateWithData(input, nil))
        let original = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(fixture, 0, nil) as? [CFString: Any])
        XCTAssertNotNil(original[kCGImagePropertyGPSDictionary])

        let jpeg = try XCTUnwrap(ChatAttachments.promptJPEG(from: input as Data))
        XCTAssertLessThanOrEqual(jpeg.count, 2 * 1024 * 1024)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(jpeg as CFData, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, UTType.jpeg.identifier)
        let info = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        let outWidth = try XCTUnwrap(info[kCGImagePropertyPixelWidth] as? Int)
        let outHeight = try XCTUnwrap(info[kCGImagePropertyPixelHeight] as? Int)
        XCTAssertGreaterThan(outHeight, outWidth, "Pixels should have the input's portrait orientation baked in")
        XCTAssertLessThanOrEqual(outHeight, 2000)
        XCTAssertNil(info[kCGImagePropertyGPSDictionary])
        XCTAssertNotNil(ChatAttachments.localPhoto(jpeg).thumbnail())
        XCTAssertNil(ChatAttachments.promptJPEG(from: Data("not a photo".utf8)))
    }

    func testOnlyPiHintSuffixesAreRemoved() {
        for text in ["[Image: 请检查这个标记]", "为什么显示 \(hint)", "我看到这一行：\n\(hint)", "```\n\(hint)\n```", "\(hint)\n是我复制的提示", "  正常正文 \n"] {
            let result = ChatAttachments.project(content: text)
            XCTAssertEqual(result.text, text)
            XCTAssertTrue(result.attachments.isEmpty)
        }
        let privateOnly = ChatAttachments.project(content: [["type": "thinking", "text": hint]])
        XCTAssertEqual(privateOnly.text, "")
        XCTAssertTrue(privateOnly.attachments.isEmpty)
    }

    func testUntrustedImagesHaveBoundedMetadataOnlyFallbacks() {
        let images = [
            ["type": "image", "url": "file:///private/example", "path": "/private/example"],
            ["type": "image", "mimeType": "image/png", "data": "??"],
            ["type": "image", "mimeType": "image/jpeg", "data": pixel],
            ["type": "image", "mimeType": "image/svg+xml", "data": pixel],
            ["type": "image", "mimeType": "image/png", "data": String(repeating: "A", count: 2_796_208)],
        ]
        let result = ChatAttachments.project(content: "", attachments: images)
        XCTAssertEqual(result.attachments.count, images.count)
        XCTAssertTrue(result.attachments.allSatisfy { $0.data == nil && $0.thumbnail() == nil })
        XCTAssertEqual(ChatAttachments.project(content: Array(repeating: ["type": "image"], count: 25)).attachments.count, 8)
    }
}
