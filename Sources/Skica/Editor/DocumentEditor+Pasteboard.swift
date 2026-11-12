import AppKit
import SkicaCore

/// Copy and paste of layers through the system pasteboard.
extension DocumentEditor {
    private static let pasteboardType = NSPasteboard.PasteboardType(LayerClipboard.pasteboardType)

    func copySelection(to pasteboard: NSPasteboard = .general) throws {
        let clipboard = LayerClipboard(copying: selection, from: document)
        guard !clipboard.isEmpty else { return }
        let data = try clipboard.encoded()
        pasteboard.clearContents()
        pasteboard.setData(data, forType: Self.pasteboardType)
    }

    var canPaste: Bool {
        NSPasteboard.general.availableType(from: [Self.pasteboardType]) != nil
    }

    func paste(from pasteboard: NSPasteboard = .general) throws {
        guard let data = pasteboard.data(forType: Self.pasteboardType) else { return }
        paste(try LayerClipboard.decode(data))
    }
}
