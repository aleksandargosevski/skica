import AppKit
import SkicaCore
import SwiftUI

/// Symbols, shared styles and palette colors: commands, name prompts and pickers.
extension DocumentWindowController {
    func performAssetCommand(_ command: CommandID) {
        switch command {
        case .createSymbol:
            guard !editor.selection.isEmpty else { return NSSound.beep() }
            let name = editor.selection.count == 1 ? editor.selectedLayers[0].name : "Symbol"
            state.prompt = PromptState(kind: .createSymbol, title: "Symbol Name", text: name, placeholder: "Button/Primary")
        case .insertSymbol: showSymbolPicker(swapping: false)
        case .swapSymbol: showSymbolPicker(swapping: true)
        case .goToMaster:
            guard editor.selectedLayers.first?.symbolInstance != nil else { return NSSound.beep() }
            editor.goToMaster()
            canvas.zoomToSelection()
        case .detachSymbol: editor.detachSelectedInstances()
        case .resetOverrides: editor.resetOverrides()
        case .createSharedStyle:
            guard let layer = editor.selectedLayers.first, !layer.isContainer || layer.isArtboard else { return NSSound.beep() }
            state.prompt = PromptState(kind: .createSharedStyle, title: "Style Name", text: layer.name, placeholder: "Card/Elevated")
        case .applySharedStyle: showSharedStylePicker()
        case .updateSharedStyle: editor.updateSharedStyleFromSelection()
        case .resetToSharedStyle: editor.resetSelectionToSharedStyle()
        case .detachSharedStyle: editor.detachSharedStyle()
        case .applyColor: showColorPicker()
        case .addColorToPalette: addSelectionColorToPalette()
        default: break
        }
    }

    /// Finishes the name prompts of this file; returns false for other prompts.
    func submitAssetPrompt(_ kind: PromptState.Kind, text: String) -> Bool {
        let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind {
        case .createSymbol:
            editor.createSymbol(named: name.isEmpty ? "Symbol" : name)
        case .createSharedStyle:
            editor.createSharedStyle(named: name.isEmpty ? "Style" : name)
        default:
            return false
        }
        return true
    }

    // MARK: Pickers

    private func showSymbolPicker(swapping: Bool) {
        let document = editor.document
        let masters = document.symbolMasters
        guard !masters.isEmpty else {
            showMessage("No symbols yet. Select layers and press ⌥⌘K to make one.")
            return NSSound.beep()
        }
        if swapping, !editor.selectedLayers.contains(where: { $0.symbolInstance != nil }) { return NSSound.beep() }
        let center = canvas.visibleCenter
        let items = masters.compactMap { id -> PaletteItem? in
            guard let master = document.layers[id], let symbolID = master.symbolID else { return nil }
            return PaletteItem(id: id.rawValue, title: master.name, subtitle: "\(Int(master.frame.width))×\(Int(master.frame.height))",
                               symbol: "diamond", run: { [weak self] in
                                   if swapping { self?.editor.swapSymbol(to: symbolID) } else { self?.editor.insertInstance(of: symbolID, centeredAt: center) }
                               })
        }
        showPicker(items, placeholder: swapping ? "Swap to symbol…" : "Insert symbol…")
    }

    private func showSharedStylePicker() {
        let layers = editor.selectedLayers
        guard !layers.isEmpty else { return NSSound.beep() }
        let wantsText = layers.allSatisfy { $0.textContent != nil }
        let styles = editor.document.assets.sharedStyles.filter { $0.isTextStyle == wantsText }
        guard !styles.isEmpty else {
            showMessage("No \(wantsText ? "text " : "")styles yet. Use Create Shared Style… on a styled layer.")
            return NSSound.beep()
        }
        let items = styles.map { style in
            PaletteItem(id: style.id.rawValue, title: style.name, subtitle: style.isTextStyle ? "Text style" : "Layer style",
                        symbol: style.isTextStyle ? "textformat" : "paintpalette", run: { [weak self] in self?.editor.applySharedStyle(style.id) })
        }
        showPicker(items, placeholder: "Apply style…")
    }

    private func showColorPicker() {
        guard !editor.selection.isEmpty else { return NSSound.beep() }
        let swatches = editor.document.assets.swatches
        guard !swatches.isEmpty else {
            showMessage("The palette is empty. Add colors with Add Color to Palette or in the inspector.")
            return NSSound.beep()
        }
        let items = swatches.map { swatch in
            PaletteItem(id: swatch.id.rawValue, title: swatch.name, subtitle: swatch.color.hex, symbol: "circle.fill",
                        run: { [weak self] in self?.editor.applyColor(swatch.color) })
        }
        showPicker(items, placeholder: "Apply color…")
    }

    private func showPicker(_ items: [PaletteItem], placeholder: String) {
        let palette = PaletteView(placeholder: placeholder, items: items, search: { _ in [] }) { [weak self] in self?.closeOverlay() }
        showOverlay(AnyView(palette), alignment: .top)
    }

    /// The first fill color (or text color) of the selection goes into the palette.
    private func addSelectionColorToPalette() {
        guard let layer = editor.selectedLayers.first else { return NSSound.beep() }
        let color = layer.textContent?.leadingStyle.color ?? layer.style.fills.first(where: { $0.isEnabled && $0.gradient == nil })?.color
        guard let color else {
            showMessage("The selection has no solid color to add.")
            return NSSound.beep()
        }
        editor.addSwatch(color)
        showMessage("Added \(color.hex) to the palette")
    }
}
