import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

struct AssistantImage: Identifiable, Codable, Hashable {
    let id: String
    let mimeType: String
    let base64Data: String
    let width: Int
    let height: Int

    var dataURL: String { "data:\(mimeType);base64,\(base64Data)" }
    var data: Data? { Data(base64Encoded: base64Data) }

    func validate() throws {
        guard mimeType == "image/jpeg", width > 0, height > 0,
              max(width, height) <= AssistantImagePreprocessor.maximumDimension,
              base64Data.utf8.count <= 700_000,
              let bytes = data, !bytes.isEmpty,
              bytes.count <= AssistantImagePreprocessor.maximumOutputBytes,
              let source = CGImageSourceCreateWithData(bytes as CFData, nil),
              CGImageSourceGetType(source) as String? == UTType.jpeg.identifier,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              properties[kCGImagePropertyPixelWidth] as? Int == width,
              properties[kCGImagePropertyPixelHeight] as? Int == height else {
            throw AssistantMediaError.invalidImage
        }
    }
}

enum AssistantMediaError: LocalizedError {
    case inputTooLarge
    case invalidImage
    case unsupportedType
    case tooManyImages
    case outputTooLarge
    var errorDescription: String? {
        switch self {
        case .inputTooLarge: return AssistantLocalization.string("图片过大，请选择 20 MB 以内、4000 万像素以内的图片。")
        case .invalidImage: return AssistantLocalization.string("无法读取这张图片，请重新选择。")
        case .unsupportedType: return AssistantLocalization.string("不支持该图片格式，请选择 JPEG、PNG、HEIC 或 WebP。")
        case .tooManyImages: return AssistantLocalization.string("每条消息最多添加 3 张图片。")
        case .outputTooLarge: return AssistantLocalization.string("图片压缩后仍过大，请裁剪后重试。")
        }
    }
}

/// All outgoing images are downsampled before decompression and re-encoded as
/// JPEG without the source EXIF/GPS dictionaries. No file URLs or public uploads.
enum AssistantImagePreprocessor {
    static let maximumInputBytes = 20 * 1024 * 1024
    static let maximumOutputBytes = 512_000
    static let maximumDimension = 1600
    static let maximumImagesPerMessage = 3

    static func prepare(_ data: Data) throws -> AssistantImage {
        guard data.count <= maximumInputBytes else { throw AssistantMediaError.inputTooLarge }
        guard let source = CGImageSourceCreateWithData(data as CFData,
            [kCGImageSourceShouldCache: false] as CFDictionary),
              let type = CGImageSourceGetType(source) as String?,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { throw AssistantMediaError.invalidImage }
        guard [UTType.jpeg.identifier, UTType.png.identifier, UTType.heic.identifier,
               UTType.heif.identifier, UTType.webP.identifier].contains(type) else {
            throw AssistantMediaError.unsupportedType
        }
        guard width <= 40_000, height <= 40_000, Int64(width) * Int64(height) <= 40_000_000 else {
            throw AssistantMediaError.inputTooLarge
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumDimension
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw AssistantMediaError.invalidImage
        }
        for quality in [0.85, 0.65, 0.45, 0.25] {
            let output = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else {
                throw AssistantMediaError.invalidImage
            }
            CGImageDestinationAddImage(destination, image,
                [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { throw AssistantMediaError.invalidImage }
            if output.length <= maximumOutputBytes {
                return AssistantImage(id: UUID().uuidString, mimeType: "image/jpeg",
                    base64Data: (output as Data).base64EncodedString(), width: image.width, height: image.height)
            }
        }
        throw AssistantMediaError.outputTooLarge
    }
}
