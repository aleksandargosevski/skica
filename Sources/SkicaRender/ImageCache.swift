import CoreGraphics
import Foundation
import ImageIO

/// Decoded images by hash, so a bitmap is decoded once rather than on every redraw.
final class ImageCache: @unchecked Sendable {
    static let shared = ImageCache()

    private let cache = NSCache<NSString, CGImage>()

    func image(hash: String, data: Data?) -> CGImage? {
        if let cached = cache.object(forKey: hash as NSString) { return cached }
        guard let data, let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else { return nil }
        cache.setObject(image, forKey: hash as NSString)
        return image
    }
}
