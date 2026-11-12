import AppKit
import UniformTypeIdentifiers

/// Reads images from the pasteboard and from drags: image files, or image data (kept as PNG).
enum ImageImport {
    static let svgType = NSPasteboard.PasteboardType(UTType.svg.identifier)
    static let draggedTypes: [NSPasteboard.PasteboardType] = [.fileURL, svgType, .png, .tiff]

    static func hasImage(on pasteboard: NSPasteboard) -> Bool {
        pasteboard.availableType(from: [.png, .tiff]) != nil || !imageFiles(on: pasteboard).isEmpty || svgData(from: pasteboard) != nil
    }

    /// SVG markup on the pasteboard: as an SVG image, or as text (copied from a code editor or Figma).
    static func svgData(from pasteboard: NSPasteboard) -> Data? {
        if let data = pasteboard.data(forType: svgType) { return data }
        guard let text = pasteboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
              text.hasPrefix("<"), text.contains("<svg"), text.hasSuffix(">") else { return nil }
        return Data(text.utf8)
    }

    static func isSVG(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .svg) == true
    }

    static func imageFiles(on pasteboard: NSPasteboard) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true,
            .urlReadingContentsConformToTypes: [UTType.image.identifier],
        ]
        return pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] ?? []
    }

    /// PNG bytes as they are; anything else (TIFF from screenshots and other apps) becomes PNG.
    static func imageData(from pasteboard: NSPasteboard) -> Data? {
        if let png = pasteboard.data(forType: .png) { return png }
        guard let tiff = pasteboard.data(forType: .tiff), let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }
}
