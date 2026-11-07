// SPDX-License-Identifier: MIT
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Sniffs image bytes and converts them into PNG that the OpenAI Images API accepts.
///
/// Gallery imports and `/images/edits` uploads both go through this so HEIC/TIFF
/// photos (common from the system picker) are stored and sent as real PNG instead
/// of being labeled `image/png` while still encoded as HEIC.
public enum ImageFileCodec {
    public enum Format: String, Sendable {
        case png
        case jpeg
        case webp
        case gif
        case heic

        public var fileExtension: String {
            switch self {
            case .png: return "png"
            case .jpeg: return "jpg"
            case .webp: return "webp"
            case .gif: return "gif"
            case .heic: return "heic"
            }
        }

        public var mimeType: String {
            switch self {
            case .png: return "image/png"
            case .jpeg: return "image/jpeg"
            case .webp: return "image/webp"
            case .gif: return "image/gif"
            case .heic: return "image/heic"
            }
        }

        /// Formats the Images API (`gpt-image-*`, `dall-e-2`) will accept as-is.
        public var isImagesAPICompatible: Bool {
            switch self {
            case .png, .jpeg, .webp: return true
            case .gif, .heic: return false
            }
        }
    }

    public enum CodecError: Error, LocalizedError {
        case unreadable
        case encodeFailed

        public var errorDescription: String? {
            switch self {
            case .unreadable:
                "This file is not a usable image. Try a PNG, JPEG, or HEIC photo."
            case .encodeFailed:
                "Could not convert this image to PNG."
            }
        }
    }

    /// Identifies the encoded format from magic bytes, ignoring the filename.
    public static func sniff(_ data: Data) -> Format? {
        guard data.count >= 12 else { return nil }
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return .png }
        if data.starts(with: [0xFF, 0xD8, 0xFF]) { return .jpeg }
        if data.starts(with: [0x47, 0x49, 0x46, 0x38]) { return .gif }
        if data[0] == 0x52, data[1] == 0x49, data[2] == 0x46, data[3] == 0x46,
           data[8] == 0x57, data[9] == 0x45, data[10] == 0x42, data[11] == 0x50 {
            return .webp
        }
        if data[4] == 0x66, data[5] == 0x74, data[6] == 0x79, data[7] == 0x70 {
            let brand = String(bytes: data[8..<12], encoding: .ascii)?.lowercased() ?? ""
            if ["heic", "heix", "hevc", "mif1", "msf1", "heif"].contains(brand) {
                return .heic
            }
        }
        return nil
    }

    /// Extension to use when writing `data` to disk. Prefers sniffed bytes so a
    /// PNG payload is never saved as `.jpg` just because a caller suggested it.
    public static func preferredFileExtension(for data: Data, suggestedFilename: String?) -> String {
        if let sniffed = sniff(data) {
            return sniffed.fileExtension
        }
        let ext = (suggestedFilename as NSString?)?.pathExtension.lowercased() ?? ""
        return ext.isEmpty ? "png" : ext
    }

    /// Decodes any ImageIO-readable photo and re-encodes it as PNG.
    ///
    /// `square` pads a non-square image onto a white canvas (`dall-e-2` requires it).
    public static func pngData(from data: Data, square: Bool = false) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw CodecError.unreadable
        }
        let prepared = square ? squared(image) : image
        return try pngData(from: prepared)
    }

    /// Converts unsupported formats (HEIC, GIF, TIFF, …) to PNG for gallery storage.
    /// PNG/JPEG/WEBP are returned unchanged.
    public static func galleryStorageData(from data: Data) throws -> (data: Data, fileExtension: String) {
        if let format = sniff(data), format.isImagesAPICompatible {
            return (data, format.fileExtension)
        }
        let png = try pngData(from: data, square: false)
        return (png, "png")
    }

    private static func pngData(from image: CGImage) throws -> Data {
        let destData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            destData,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw CodecError.encodeFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw CodecError.encodeFailed
        }
        return destData as Data
    }

    /// Pads `image` onto a square white canvas so `dall-e-2` will accept it.
    private static func squared(_ image: CGImage) -> CGImage {
        let width = image.width
        let height = image.height
        let side = max(width, height)
        guard width > 0, height > 0, width != height else { return image }
        let colorSpace = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return image
        }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
        let originX = (side - width) / 2
        let originY = (side - height) / 2
        ctx.draw(image, in: CGRect(x: originX, y: originY, width: width, height: height))
        return ctx.makeImage() ?? image
    }
}
