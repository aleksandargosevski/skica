import AppKit
import SkicaCore

/// The AppKit side of a `.skica` file: saving, autosave, versions and the window.
@objc(SkicaDocument)
final class SkicaDocument: NSDocument {
    static let typeIdentifier = "io.github.aleksandargosevski.skica.document"

    let editor = DocumentEditor(document: Document())

    override init() {
        super.init()
        editor.undoManager = undoManager
    }

    override class var autosavesInPlace: Bool { true }

    override func makeWindowControllers() {
        addWindowController(DocumentWindowController(editor: editor))
    }

    /// Sketch and SVG files normally open through `SkicaDocumentController` as untitled copies;
    /// this covers other ways AppKit may read them.
    override func read(from data: Data, ofType typeName: String) throws {
        switch typeName {
        case Self.typeIdentifier: editor.replaceDocument(try DocumentArchive.decode(data))
        case "public.svg-image": editor.replaceDocument(try DocumentImport.svgDocument(data, name: displayName ?? "SVG"))
        default: editor.replaceDocument(try SketchImporter.document(from: data))
        }
    }

    override func data(ofType typeName: String) throws -> Data {
        editor.breakCoalescing()
        return try DocumentArchive.encode(editor.document)
    }
}
