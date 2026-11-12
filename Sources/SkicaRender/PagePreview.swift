import CoreGraphics
import Foundation
import SkicaCore

/// A picture of a document for Finder thumbnails and Quick Look: the first page with layers,
/// scaled to fit.
public enum PagePreview {
    /// Draws into a context with the origin at the bottom left (as Quick Look provides).
    /// Returns false when the document has nothing to show.
    @discardableResult
    public static func draw(_ document: Document, in context: CGContext, size: CGSize) -> Bool {
        guard let (page, bounds) = visiblePage(of: document), size.width > 0, size.height > 0 else { return false }
        let scale = min(size.width / bounds.width, size.height / bounds.height)
        context.saveGState()
        defer { context.restoreGState() }
        context.translateBy(x: (size.width - bounds.width * scale) / 2, y: size.height - (size.height - bounds.height * scale) / 2)
        context.scaleBy(x: scale, y: -scale)
        context.translateBy(x: -bounds.minX, y: -bounds.minY)
        CanvasRenderer(options: RenderOptions(showsArtboardShadows: false)).draw(page: page, of: document, in: context, visibleRect: bounds)
        return true
    }

    /// The preview as PNG, its longer side `maximumSide` pixels at most.
    public static func png(of document: Document, maximumSide: Double) throws -> Data {
        guard let (_, bounds) = visiblePage(of: document) else { throw ExportError.nothingToExport }
        let scale = min(maximumSide / max(bounds.width, bounds.height), 2)
        let width = max(Int((bounds.width * scale).rounded()), 1)
        let height = max(Int((bounds.height * scale).rounded()), 1)
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw ExportError.tooLarge(width: width, height: height) }
        draw(document, in: context, size: CGSize(width: width, height: height))
        guard let image = context.makeImage() else { throw ExportError.encodingFailed("preview") }
        return try Exporter.encode(image, as: .png)
    }

    /// The largest size with the preview's proportions that fits `maximum`.
    public static func size(of document: Document, fitting maximum: CGSize) -> CGSize? {
        guard let (_, bounds) = visiblePage(of: document) else { return nil }
        let scale = min(maximum.width / bounds.width, maximum.height / bounds.height)
        return CGSize(width: max((bounds.width * scale).rounded(), 1), height: max((bounds.height * scale).rounded(), 1))
    }

    /// The first page with layers and their bounds, with a small margin.
    static func visiblePage(of document: Document) -> (Page, CGRect)? {
        for page in document.pages {
            guard let bounds = document.contentBounds(of: page), bounds.width > 0, bounds.height > 0 else { continue }
            let margin = max(bounds.width, bounds.height) * 0.02
            return (page, bounds.insetBy(dx: -margin, dy: -margin))
        }
        return nil
    }
}
