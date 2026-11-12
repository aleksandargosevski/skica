import AppKit
import SkicaCore

/// Development aid: `SKICA_DEBUG_SNAPSHOT=out.png Skica.app/Contents/MacOS/Skica` opens the sample
/// document and writes its window contents to a PNG, without needing screen recording access.
/// `SKICA_DEBUG_COMMANDS=selectNext,enterSelection` runs commands (by name) before the snapshot;
/// `SKICA_DEBUG_SIZE=1440x900` fixes the window size and panel widths.
/// `undo`, `redo`, `nudge` (⇧→), `addSwatch`, `cropDemo` (an image added, cropped and in crop mode), `pasteSVG` (an icon pasted as SVG text), `select:Layer Name|Other Layer` and `run:w 200; h 40`
/// (a command line), and `type:text` (fills the open prompt) are also understood.
@MainActor
enum DebugSnapshot {
    static func captureSampleDocument(to url: URL, commands: [String], openSample: @escaping () -> DocumentWindowController?) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            let controller = openSample()
            // Source-list selection is drawn by a vibrant material that cacheDisplay renders black.
            controller?.layersPanel.outlineView.style = .inset
            controller?.layersPanel.outlineView.selectionHighlightStyle = .regular
            if let size = ProcessInfo.processInfo.environment["SKICA_DEBUG_SIZE"], let controller {
                // The same window and panels on every run, whatever this Mac remembers.
                let parts = size.split(separator: "x").compactMap { Double($0) }
                if parts.count == 2 { controller.window?.setContentSize(NSSize(width: parts[0], height: parts[1])) }
                _ = controller.debugResizePanels(layers: 240, inspector: 300)
                controller.perform(.zoomToFit)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                for name in commands {
                    switch name {
                    case "undo": controller?.window?.undoManager?.undo(); continue
                    case "redo": controller?.window?.undoManager?.redo(); continue
                    case "nudge": controller?.handleArrow(dx: 1, dy: 0, modifiers: .shift); continue
                    case "addSwatch": controller?.editor.addSwatch(SkicaCore.Color(hex: "#30A46C")!, name: "Green"); continue
                    case "resizePanels":
                        let result = controller?.debugResizePanels(layers: 360, inspector: 420) ?? "no window"
                        FileHandle.standardError.write(Data("resizePanels: \(result)\n".utf8))
                        continue
                    case "cropDemo":
                        if let controller { cropDemo(controller) }
                        continue
                    case "pasteSVG":
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(debugSVG, forType: .string)
                        controller?.paste(nil)
                        continue
                    default: break
                    }
                    if name.hasPrefix("type:"), let controller {
                        // An open prompt (command line, size…) showing this text, as if typed.
                        controller.state.prompt?.text = String(name.dropFirst("type:".count))
                        continue
                    }
                    if name.hasPrefix("run:"), let controller {
                        do {
                            _ = try controller.editor.run(commandLine: String(name.dropFirst("run:".count)))
                        } catch {
                            FileHandle.standardError.write(Data("Command line failed: \(error)\n".utf8))
                        }
                        continue
                    }
                    if name.hasPrefix("select:"), let controller {
                        let names = name.dropFirst("select:".count).split(separator: "|").map(String.init)
                        let order = controller.editor.document.listOrder(of: controller.editor.page)
                        let ids = names.compactMap { layerName in order.first { controller.editor.document.layers[$0]?.name == layerName } }
                        controller.editor.select(ids)
                        continue
                    }
                    guard let command = CommandID(rawValue: name) else {
                        FileHandle.standardError.write(Data("Unknown command \(name)\n".utf8))
                        continue
                    }
                    controller?.perform(command)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    do {
                        try capture(controller?.window, to: url)
                    } catch {
                        FileHandle.standardError.write(Data("Snapshot failed: \(error.localizedDescription)\n".utf8))
                    }
                }
            }
        }
    }

    private static func capture(_ window: NSWindow?, to url: URL) throws {
        guard let view = window?.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw CocoaError(.fileWriteUnknown)
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try png.write(to: url)
        try captureLayers(of: window, to: url.deletingPathExtension().appendingPathExtension("layers.png"))
    }

    /// The canvas as composited from its layers' backing stores, i.e. what was drawn on screen
    /// (cacheDisplay redraws views into a bitmap, which can differ, e.g. for shadows).
    private static func captureLayers(of window: NSWindow?, to url: URL) throws {
        guard let canvas = (window?.windowController as? DocumentWindowController)?.canvas, let layer = canvas.layer else { return }
        let scale = window?.backingScaleFactor ?? 2
        let width = Int(canvas.bounds.width * scale)
        let height = Int(canvas.bounds.height * scale)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw CocoaError(.fileWriteUnknown) }
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        layer.render(in: context)
        guard let image = context.makeImage() else { throw CocoaError(.fileWriteUnknown) }
        let rep = NSBitmapImageRep(cgImage: image)
        try rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}

private let debugSVG = """
<svg xmlns="http://www.w3.org/2000/svg" width="240" height="240" viewBox="0 0 24 24" fill="none" stroke="#E54666" stroke-width="2" \
stroke-linecap="round" stroke-linejoin="round"><path d="M20.8 4.6a5.5 5.5 0 0 0-7.8 0L12 5.7l-1-1.1a5.5 5.5 0 0 0-7.8 7.8l1 1.1L12 21l7.8-7.5 1-1.1a5.5 5.5 0 0 0 0-7.8z"/>\
<circle cx="12" cy="10" r="2" fill="#5B5BD6" stroke="none"/></svg>
"""

/// Adds the app icon as an image in the Desktop artboard, crops it to its middle and starts cropping.
@MainActor
private func cropDemo(_ controller: DocumentWindowController) {
    guard let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"), let image = NSImage(contentsOf: url),
          let tiff = image.tiffRepresentation, let data = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]),
          let id = controller.editor.insertImage(data, named: "Photo", centeredAt: CGPoint(x: 1100, y: 700)),
          let layer = controller.editor.document.layers[id] else { return }
    let frame = layer.frame.cgRect
    controller.editor.perform("Crop") { transaction in
        transaction.setCrop(id, frame: frame.insetBy(dx: frame.width * 0.25, dy: frame.height * 0.15), imageRect: frame)
    }
    controller.canvas.beginCropping(id)
}
