import AppKit
import SkicaCore

/// Asks for a Figma link (and a token the first time), downloads the file and opens it as a
/// new untitled document.
@MainActor
enum FigmaImport {
    static func run(opening controller: SkicaDocumentController) {
        guard let request = ask() else { return }
        if request.remember {
            do {
                try FigmaToken.save(request.token)
            } catch {
                NSApp.presentError(error)
            }
        }
        let progress = ProgressWindow(message: "Importing from Figma…")
        Task {
            defer { progress.close() }
            do {
                let document = try await FigmaImporter.document(fileKey: request.key, token: request.token)
                controller.openUntitled(document, displayName: "Figma \(request.key)")
            } catch {
                let alert = NSAlert()
                alert.messageText = "The Figma file could not be imported."
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
    }

    private static func ask() -> (key: String, token: String, remember: Bool)? {
        let saved = FigmaToken.load()
        let alert = NSAlert()
        alert.messageText = "Import from Figma"
        alert.informativeText = "Paste the link of a Figma design file. Figma needs a personal access token (Settings → Security → Personal access tokens) with read access to files."
        alert.addButton(withTitle: "Import")
        alert.addButton(withTitle: "Cancel")

        let link = NSTextField(frame: NSRect(x: 0, y: 56, width: 360, height: 24))
        link.placeholderString = "https://www.figma.com/design/…"
        if let text = NSPasteboard.general.string(forType: .string), FigmaImporter.fileKey(from: text) != nil, text.contains("figma.com") {
            link.stringValue = text
        }
        let token = NSSecureTextField(frame: NSRect(x: 0, y: 28, width: 360, height: 24))
        token.placeholderString = saved == nil ? "Personal access token" : "Saved token (type to replace)"
        let remember = NSButton(checkboxWithTitle: "Remember the token in ~/.config/skica/figma-token", target: nil, action: nil)
        remember.frame = NSRect(x: 0, y: 0, width: 360, height: 20)
        remember.state = saved == nil ? .on : .off
        let fields = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 80))
        [link, token, remember].forEach(fields.addSubview)
        alert.accessoryView = fields
        alert.window.initialFirstResponder = link

        while alert.runModal() == .alertFirstButtonReturn {
            let typed = token.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let key = FigmaImporter.fileKey(from: link.stringValue) else {
                alert.informativeText = "That is not a Figma file link. It looks like https://www.figma.com/design/KEY/Name."
                continue
            }
            guard let value = typed.isEmpty ? saved : typed else {
                alert.informativeText = "Figma needs a personal access token to share the file with Skica."
                continue
            }
            return (key, value, remember.state == .on && !typed.isEmpty)
        }
        return nil
    }
}

/// A small floating panel with a spinner while something slow runs.
@MainActor
private final class ProgressWindow {
    private let panel: NSPanel

    init(message: String) {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 280, height: 64), styleMask: [.titled, .hudWindow, .utilityWindow],
                        backing: .buffered, defer: false)
        panel.title = "Skica"
        let spinner = NSProgressIndicator(frame: NSRect(x: 20, y: 22, width: 20, height: 20))
        spinner.style = .spinning
        spinner.startAnimation(nil)
        let label = NSTextField(labelWithString: message)
        label.frame = NSRect(x: 52, y: 22, width: 210, height: 20)
        panel.contentView?.addSubview(spinner)
        panel.contentView?.addSubview(label)
        panel.center()
        panel.orderFrontRegardless()
    }

    func close() {
        panel.close()
    }
}
