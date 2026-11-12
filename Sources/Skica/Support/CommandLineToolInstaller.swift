import AppKit

/// Links `skica` (bundled in Contents/Helpers) into a folder on the PATH.
@MainActor
enum CommandLineToolInstaller {
    private static let candidates = ["/opt/homebrew/bin", "/usr/local/bin"]

    static func install() {
        let tool = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/skica")
        guard FileManager.default.isExecutableFile(atPath: tool.path) else {
            return show("The command-line tool is missing from this copy of Skica.", detail: tool.path)
        }
        let fileManager = FileManager.default
        for folder in candidates where fileManager.isWritableFile(atPath: folder) {
            let link = URL(fileURLWithPath: folder).appendingPathComponent("skica")
            do {
                if (try? link.checkResourceIsReachable()) == true || (try? fileManager.destinationOfSymbolicLink(atPath: link.path)) != nil {
                    try fileManager.removeItem(at: link)
                }
                try fileManager.createSymbolicLink(at: link, withDestinationURL: tool)
                return show("Installed “skica” in \(folder).", detail: "Try: skica export Design.skica -f png -s 2x")
            } catch {
                return show("Could not install the command-line tool.", detail: error.localizedDescription)
            }
        }
        let command = "sudo ln -sf '\(tool.path)' /usr/local/bin/skica"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        show("No writable folder on the PATH was found.", detail: "Run this in Terminal (it is on the clipboard):\n\(command)")
    }

    private static func show(_ message: String, detail: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.runModal()
    }
}
