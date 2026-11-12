import AppKit
import SkicaCore
import SkicaRender
import UniformTypeIdentifiers

/// Exporting files, PDFs of pages, and copying layers as images.
extension DocumentWindowController {
    private static let exportFolderKey = "ExportFolder"

    /// The selected layers with their export presets (a 1x PNG for layers without any).
    func exportSelection() {
        guard !editor.selection.isEmpty else { return NSSound.beep() }
        export(editor.selection)
    }

    /// Every layer in the document that has export presets.
    func exportMarked() {
        let ids = editor.document.exportableLayers
        guard !ids.isEmpty else {
            showMessage("No layers are marked for export. Add an export size in the inspector.")
            return NSSound.beep()
        }
        export(ids)
    }

    /// The artboards of the current page as pages of one PDF.
    func exportPagePDF() {
        let page = editor.page
        let artboards = editor.document.artboards(on: page)
        guard let window, !artboards.isEmpty else {
            showMessage("This page has no artboards to export.")
            return NSSound.beep()
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = page.name + ".pdf"
        panel.directoryURL = lastExportFolder
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            let document = self.editor.document
            self.runInBackground(describe: { _ in "Exported \(artboards.count) artboard\(artboards.count == 1 ? "" : "s") to \(url.lastPathComponent)" }) {
                try Exporter.pdf(of: artboards, in: document).write(to: url, options: .atomic)
                return [url]
            }
        }
    }

    func copyAsPNG() {
        guard let id = editor.selection.first else { return NSSound.beep() }
        do {
            let image = try Exporter.image(of: id, in: editor.document, scale: 2)
            let data = try Exporter.encode(image, as: .png)
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setData(data, forType: .png)
            showMessage("Copied \(editor.document.layers[id]?.name ?? "layer") as PNG at 2x")
        } catch {
            presentError(error)
        }
    }

    func copyAsSVG() {
        guard let id = editor.selection.first, let svg = SVGWriter.svg(of: id, in: editor.document) else { return NSSound.beep() }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(svg, forType: .string)
        pasteboard.setData(Data(svg.utf8), forType: NSPasteboard.PasteboardType(UTType.svg.identifier))
        showMessage("Copied \(editor.document.layers[id]?.name ?? "layer") as SVG")
    }

    /// Shows a note in the status line for a few seconds.
    func showMessage(_ text: String) {
        state.message = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            if self?.state.message == text { self?.state.message = nil }
        }
    }

    // MARK: Helpers

    private func export(_ ids: [LayerID]) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export"
        panel.message = "Choose a folder for the exported files"
        panel.directoryURL = lastExportFolder
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let folder = panel.url, let self else { return }
            UserDefaults.standard.set(folder.path, forKey: Self.exportFolderKey)
            let document = self.editor.document
            self.runInBackground(describe: { urls in "Exported \(urls.count) file\(urls.count == 1 ? "" : "s") to \(folder.lastPathComponent)" }) {
                let files = try Exporter.files(for: ids, in: document)
                return try files.map { file in
                    let url = folder.appendingPathComponent(file.path)
                    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try file.data.write(to: url, options: .atomic)
                    return url
                }
            }
        }
    }

    /// Exports off the main thread (the document is a value, so the canvas stays editable)
    /// and reports the result in the status line.
    private func runInBackground(describe: @escaping ([URL]) -> String, work: @escaping @Sendable () throws -> [URL]) {
        showMessage("Exporting…")
        Task.detached {
            do {
                let urls = try work()
                await MainActor.run { [weak self] in self?.showMessage(describe(urls)) }
            } catch {
                await MainActor.run { [weak self] in
                    self?.state.message = nil
                    self?.presentError(error)
                }
            }
        }
    }

    private var lastExportFolder: URL {
        if let path = UserDefaults.standard.string(forKey: Self.exportFolderKey) {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
    }
}
