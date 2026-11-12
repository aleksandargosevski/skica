import AppKit
import SkicaCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var keymap = Keymap()
    private var keymapWarnings: [String] = []
    private lazy var router = KeyboardRouter { [unowned self] in self.keymap }

    /// The first document controller made becomes the shared one, so this one must exist early.
    private let documentController = SkicaDocumentController()

    func applicationWillFinishLaunching(_ notification: Notification) {
        (keymap, keymapWarnings) = KeymapStore().load()
        NSApp.mainMenu = MainMenu.build(keymap: keymap)
        router.install()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let environment = ProcessInfo.processInfo.environment
        if let path = environment["SKICA_DEBUG_SNAPSHOT"] {
            let commands = environment["SKICA_DEBUG_COMMANDS"]?.split(separator: ",").map(String.init) ?? []
            DebugSnapshot.captureSampleDocument(to: URL(fileURLWithPath: path), commands: commands) { [weak self] in
                var model = SampleDocuments.showcase()
                if let file = environment["SKICA_DEBUG_OPEN"] {
                    do {
                        model = try DocumentImport.document(at: URL(fileURLWithPath: file))
                    } catch {
                        FileHandle.standardError.write(Data("Cannot open \(file): \(error.localizedDescription)\n".utf8))
                    }
                }
                return self?.openUntitled(model)?.windowControllers.first as? DocumentWindowController
            }
        }
        if !keymapWarnings.isEmpty {
            let alert = NSAlert()
            alert.messageText = "Some shortcuts in keybindings.json were skipped"
            alert.informativeText = keymapWarnings.joined(separator: "\n")
            alert.runModal()
        }
    }

    @objc func installCommandLineTool(_ sender: Any?) {
        CommandLineToolInstaller.install()
    }

    @objc func importFromFigma(_ sender: Any?) {
        FigmaImport.run(opening: documentController)
    }

    @objc func newSampleDocument(_ sender: Any?) {
        openUntitled(SampleDocuments.showcase())
    }

    @objc func newStressDocument(_ sender: Any?) {
        openUntitled(SampleDocuments.stress())
    }

    @discardableResult
    private func openUntitled(_ model: Document) -> SkicaDocument? {
        documentController.openUntitled(model)
    }
}
