import AppKit
import SkicaCore

/// Opens Sketch and SVG files as new, untitled Skica documents (saving asks where to keep the
/// .skica file), and Skica files as usual.
@MainActor
final class SkicaDocumentController: NSDocumentController {
    override func openDocument(withContentsOf url: URL, display displayDocument: Bool,
                               completionHandler: @escaping (NSDocument?, Bool, Error?) -> Void) {
        guard DocumentImport.fileExtensions.contains(url.pathExtension.lowercased()) else {
            return super.openDocument(withContentsOf: url, display: displayDocument, completionHandler: completionHandler)
        }
        Task {
            do {
                let model = try await Task.detached(priority: .userInitiated) { try DocumentImport.document(at: url) }.value
                let document = openUntitled(model, displayName: url.deletingPathExtension().lastPathComponent)
                noteNewRecentDocumentURL(url)
                completionHandler(document, false, nil)
            } catch {
                completionHandler(nil, false, Self.importError(error, url: url))
            }
        }
    }

    /// A new window showing `model`, not yet saved anywhere.
    @discardableResult
    func openUntitled(_ model: Document, displayName: String? = nil) -> SkicaDocument? {
        do {
            guard let document = try makeUntitledDocument(ofType: SkicaDocument.typeIdentifier) as? SkicaDocument else { return nil }
            document.editor.replaceDocument(model)
            if let displayName { document.displayName = displayName }
            addDocument(document)
            document.makeWindowControllers()
            document.showWindows()
            return document
        } catch {
            NSApp.presentError(error)
            return nil
        }
    }

    private static func importError(_ error: Error, url: URL) -> NSError {
        NSError(domain: "Skica", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "\(url.lastPathComponent) could not be imported.",
            NSLocalizedRecoverySuggestionErrorKey: error.localizedDescription,
        ])
    }
}
