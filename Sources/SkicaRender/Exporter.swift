import CoreGraphics
import Foundation
import ImageIO
import libwebp
import SkicaCore
import UniformTypeIdentifiers

/// A file produced by an export; `path` is relative to the export folder and may contain
/// folders (from layer names like `Icons/Home`).
public struct ExportedFile: Equatable, Sendable {
    public var path: String
    public var data: Data
}

public enum ExportError: LocalizedError, Equatable {
    case nothingToExport
    case tooLarge(width: Int, height: Int)
    case encodingFailed(String)

    public var errorDescription: String? {
        switch self {
        case .nothingToExport: "There is nothing to export."
        case .tooLarge(let width, let height): "The image would be \(width) × \(height) pixels, which is too large. Use a smaller size."
        case .encodingFailed(let format): "The \(format) file could not be written."
        }
    }
}

/// Renders layers to PNG, JPG, WebP, HEIC, AVIF, PDF and SVG, with the same renderer as the canvas.
public enum Exporter {
    /// Every file for `ids`, using each layer's presets, or `presets` for all when given
    /// (layers without presets get a 1x PNG).
    public static func files(for ids: [LayerID], in document: Document, presets override: [ExportPreset]? = nil) throws -> [ExportedFile] {
        var files: [ExportedFile] = []
        var usedPaths = Set<String>()
        for id in ids {
            guard let layer = document.layers[id] else { continue }
            let presets = override ?? (layer.exports.isEmpty ? [ExportPreset()] : layer.exports)
            for preset in presets {
                var path = document.exportName(of: id) + preset.suffix + "." + preset.format.rawValue
                // Layers with the same name get numbered rather than overwriting each other.
                var counter = 2
                while usedPaths.contains(path) {
                    path = document.exportName(of: id) + " \(counter)" + preset.suffix + "." + preset.format.rawValue
                    counter += 1
                }
                usedPaths.insert(path)
                files.append(ExportedFile(path: path, data: try data(for: id, in: document, preset: preset)))
            }
        }
        guard !files.isEmpty else { throw ExportError.nothingToExport }
        return files
    }

    public static func data(for id: LayerID, in document: Document, preset: ExportPreset) throws -> Data {
        switch preset.format {
        case .svg:
            guard let svg = SVGWriter.svg(of: id, in: document) else { throw ExportError.nothingToExport }
            return Data(svg.utf8)
        case .pdf:
            return try pdf(of: [id], in: document)
        case .png, .jpg, .webp, .heic, .avif:
            guard let bounds = document.exportBounds(of: id) else { throw ExportError.nothingToExport }
            let scale = preset.size.scale(for: bounds.width, height: bounds.height)
            let image = try self.image(of: id, in: document, scale: scale, opaque: preset.format == .jpg)
            return try encode(image, as: preset.format)
        }
    }

    /// The layer drawn at `scale`; `opaque` puts it on white (for formats without transparency).
    public static func image(of id: LayerID, in document: Document, scale: Double, opaque: Bool = false) throws -> CGImage {
        guard let bounds = document.exportBounds(of: id), bounds.width > 0, bounds.height > 0 else { throw ExportError.nothingToExport }
        let width = max(Int((bounds.width * scale).rounded()), 1)
        let height = max(Int((bounds.height * scale).rounded()), 1)
        guard width * height <= 400_000_000 else { throw ExportError.tooLarge(width: width, height: height) }
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw ExportError.tooLarge(width: width, height: height) }
        if opaque {
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: CGFloat(width) / bounds.width, y: -CGFloat(height) / bounds.height)
        draw(id, of: document, in: context, bounds: bounds)
        guard let image = context.makeImage() else { throw ExportError.encodingFailed("image") }
        return image
    }

    /// A PDF with one page per layer, sized to each layer; shapes and text stay vectors.
    public static func pdf(of ids: [LayerID], in document: Document) throws -> Data {
        let data = NSMutableData()
        guard !ids.isEmpty, let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: nil, nil) else { throw ExportError.nothingToExport }
        for id in ids {
            guard let bounds = document.exportBounds(of: id) else { continue }
            var mediaBox = CGRect(origin: .zero, size: bounds.size)
            context.beginPage(mediaBox: &mediaBox)
            context.translateBy(x: 0, y: bounds.height)
            context.scaleBy(x: 1, y: -1)
            draw(id, of: document, in: context, bounds: bounds)
            context.endPage()
        }
        context.closePDF()
        return data as Data
    }

    /// Encodes with Image I/O, or libwebp for WebP (Image I/O cannot write it).
    public static func encode(_ image: CGImage, as format: ExportPreset.Format) throws -> Data {
        switch format {
        case .webp:
            return try webp(image)
        case .png, .jpg, .heic, .avif:
            let type: UTType = switch format {
            case .jpg: .jpeg
            case .heic: .heic
            case .avif: UTType("public.avif") ?? .png
            default: .png
            }
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else {
                throw ExportError.encodingFailed(format.title)
            }
            let properties: [CFString: Any] = format == .png ? [:] : [kCGImageDestinationLossyCompressionQuality: 0.9]
            CGImageDestinationAddImage(destination, image, properties as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { throw ExportError.encodingFailed(format.title) }
            return data as Data
        case .pdf, .svg:
            throw ExportError.encodingFailed(format.title)
        }
    }

    /// Draws a layer (made visible, as exporting a hidden layer means showing it) so that
    /// `bounds` fills the context's current coordinates.
    private static func draw(_ id: LayerID, of document: Document, in context: CGContext, bounds: CGRect) {
        var document = document
        document.layers[id]?.isVisible = true
        context.translateBy(x: -bounds.minX, y: -bounds.minY)
        context.concatenate(document.parentSpace(of: id))
        CanvasRenderer().draw(id, of: document, in: context, visibleRect: nil)
    }

    /// Lossy WebP at quality 90 with alpha; libwebp wants straight (not premultiplied) RGBA.
    private static func webp(_ image: CGImage) throws -> Data {
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw ExportError.encodingFailed("WebP") }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = Int(pixels[offset + 3])
            guard alpha > 0, alpha < 255 else { continue }
            for channel in 0..<3 {
                pixels[offset + channel] = UInt8(min(Int(pixels[offset + channel]) * 255 / alpha, 255))
            }
        }
        var output: UnsafeMutablePointer<UInt8>?
        let size = WebPEncodeRGBA(&pixels, Int32(width), Int32(height), Int32(width * 4), 90, &output)
        guard size > 0, let output else { throw ExportError.encodingFailed("WebP") }
        defer { WebPFree(output) }
        return Data(bytes: output, count: size)
    }
}
