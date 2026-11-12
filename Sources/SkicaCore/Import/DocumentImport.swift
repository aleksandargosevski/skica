import CoreGraphics
import Foundation

/// Opens design files of other apps as Skica documents.
public enum DocumentImport {
    public static let fileExtensions = ["sketch", "svg"]

    /// A `.skica`, `.sketch` or `.svg` file as a document.
    public static func document(at url: URL) throws -> Document {
        let data = try Data(contentsOf: url)
        switch url.pathExtension.lowercased() {
        case "sketch":
            return try finished(SketchImporter.document(from: data))
        case "svg":
            return try svgDocument(data, name: url.deletingPathExtension().lastPathComponent, baseURL: url.deletingLastPathComponent())
        default:
            return try DocumentArchive.decode(data)
        }
    }

    /// An SVG on an artboard of its canvas size (or of its contents when it declares none).
    public static func svgDocument(_ data: Data, name: String, baseURL: URL? = nil) throws -> Document {
        let clipboard = try SVGImporter.clipboard(from: data, name: name, baseURL: baseURL)
        let contents = clipboard.roots.compactMap { clipboard.layers[$0]?.frame.cgRect }.reduce(CGRect.null) { $0.union($1) }
        let canvas = SVGImporter.canvasSize(of: data).map { CGRect(origin: .zero, size: $0) } ?? contents
        var transaction = Transaction(Document())
        let page = transaction.document.pages[0].id
        let artboard = Layer(name: name, kind: .artboard, frame: Rect(canvas.integral), style: Style())
        transaction.insert(artboard, into: .page(page))
        _ = transaction.paste(clipboard, into: .layer(artboard.id))
        transaction.finalize()
        return transaction.document
    }

    /// Checks that the imported layer tree is consistent before anyone edits it.
    static func finished(_ document: Document) throws -> Document {
        try document.validate()
        return document
    }
}
