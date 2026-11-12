import CoreGraphics
import CryptoKit
import Foundation
import ImageIO

extension Transaction {
    /// Stores image bytes in the document (once per distinct image) and returns their hash.
    /// Images are not part of patches: they stay in the document until it is saved, when
    /// unreferenced ones are dropped, so undo and redo never lose them.
    @discardableResult
    public mutating func addImage(_ data: Data) -> String {
        let hash = ImageData.hash(of: data)
        if document.images[hash] == nil { storeImage(data, hash: hash) }
        return hash
    }
}

public enum ImageData {
    public static func hash(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// The size an image is shown at: pixels at 72 dpi as points, or fewer points for
    /// high-density images (a 144 dpi image shows at half its pixel size).
    public static func naturalSize(of data: Data) -> CGSize? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
              let height = properties[kCGImagePropertyPixelHeight] as? CGFloat else { return nil }
        let dpi = (properties[kCGImagePropertyDPIWidth] as? CGFloat).flatMap { $0 > 0 ? $0 : nil } ?? 72
        let scale = max(dpi / 72, 1)
        return CGSize(width: (width / scale).rounded(), height: (height / scale).rounded())
    }

    /// The file extension that matches the bytes, for the archive.
    public static func fileExtension(of data: Data) -> String {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source) as String? else { return "bin" }
        switch type {
        case "public.png": return "png"
        case "public.jpeg": return "jpg"
        case "public.heic": return "heic"
        case "org.webmproject.webp": return "webp"
        case "com.compuserve.gif": return "gif"
        case "public.tiff": return "tiff"
        default: return "bin"
        }
    }
}
