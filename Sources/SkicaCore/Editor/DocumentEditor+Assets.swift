import CoreGraphics
import Foundation

/// Symbols, shared styles and the color palette.
extension DocumentEditor {
    // MARK: Symbols

    /// Makes a symbol of the selection; the selection becomes its instance (or the master, for an artboard).
    public func createSymbol(named name: String) {
        guard !selection.isEmpty else { return }
        performSelecting("Create Symbol") { transaction in
            guard let created = transaction.createSymbol(from: selection, name: name) else { return selection }
            return [created.instance ?? created.master]
        }
    }

    @discardableResult
    public func insertInstance(of symbolID: SymbolID, centeredAt center: CGPoint) -> LayerID? {
        var inserted: LayerID?
        perform("Insert Symbol") { inserted = $0.insertInstance(of: symbolID, centeredAt: center, on: pageID) }
        if let inserted { select([inserted]) }
        return inserted
    }

    public func detachSelectedInstances() {
        performSelecting("Detach") { transaction in
            let groups = selection.compactMap { transaction.detach(instance: $0) }
            return groups.isEmpty ? selection : groups
        }
    }

    public func swapSymbol(to symbolID: SymbolID) {
        updateSelection("Swap Symbol") { layer in
            guard var instance = layer.symbolInstance else { return }
            instance.symbolID = symbolID
            instance.overrides = [:]
            layer.kind = .symbolInstance(instance)
        }
    }

    public func setOverride(_ layerID: LayerID, coalescingKey: String? = nil, _ body: @escaping (inout LayerOverride) -> Void) {
        perform("Change Override", coalescingKey: coalescingKey) { transaction in
            for id in selection where transaction[id]?.symbolInstance != nil {
                transaction.setOverride(layerID, in: id, body)
            }
        }
    }

    public func resetOverrides() {
        updateSelection("Reset Overrides") { layer in
            guard var instance = layer.symbolInstance else { return }
            instance.overrides = [:]
            layer.kind = .symbolInstance(instance)
        }
    }

    /// Shows the master of the selected instance and selects it.
    public func goToMaster() {
        guard let symbolID = selectedLayers.first?.symbolInstance?.symbolID,
              let master = document.master(of: symbolID), let page = document.pageID(of: master) else { return }
        showPage(page)
        select([master])
    }

    /// Deleting a master first turns its instances into groups.
    public func deleteSelectionDetachingInstances() {
        let masters = document.topmostOnly(selection).compactMap { document.layers[$0]?.symbolID }
        guard !masters.isEmpty else { return deleteSelection() }
        let ids = document.topmostOnly(selection)
        perform("Delete Symbol", select: []) { transaction in
            for symbolID in masters { transaction.detachInstances(of: symbolID) }
            for id in ids { transaction.remove(id) }
        }
    }

    // MARK: Shared styles

    public func createSharedStyle(named name: String) {
        guard let id = selection.first else { return }
        perform("Create Style") { $0.createSharedStyle(from: id, name: name) }
    }

    public func applySharedStyle(_ styleID: SharedStyleID) {
        perform("Apply Style") { $0.applySharedStyle(styleID, to: selection) }
    }

    /// Changes the style to the selected layer's look and updates every layer using it.
    public func updateSharedStyleFromSelection() {
        guard let id = selection.first, let styleID = document.layers[id]?.sharedStyleID else { return }
        perform("Update Style") { $0.updateSharedStyle(styleID, from: id) }
    }

    public func resetSelectionToSharedStyle() {
        perform("Reset Style") { $0.resetToSharedStyle(selection) }
    }

    public func detachSharedStyle() {
        perform("Detach Style") { $0.detachSharedStyle(selection) }
    }

    public func renameSharedStyle(_ styleID: SharedStyleID, to name: String) {
        perform("Rename Style") { $0.renameSharedStyle(styleID, to: name) }
    }

    public func deleteSharedStyle(_ styleID: SharedStyleID) {
        perform("Delete Style") { $0.deleteSharedStyle(styleID) }
    }

    // MARK: Swatches

    public func addSwatch(_ color: Color, name: String? = nil) {
        perform("Add Color") { $0.addSwatch(color, name: name) }
    }

    public func updateSwatch(_ id: SwatchID, coalescingKey: String? = nil, _ body: @escaping (inout Swatch) -> Void) {
        perform("Change Color", coalescingKey: coalescingKey) { $0.updateSwatch(id, body) }
    }

    public func deleteSwatch(_ id: SwatchID) {
        perform("Delete Color") { $0.deleteSwatch(id) }
    }

    /// Paints the selection with a color: text gets it as text color, shapes as their first fill.
    public func applyColor(_ color: Color) {
        updateSelection("Apply Color") { layer in
            if var content = layer.textContent {
                content.updateStyles { $0.color = color }
                layer.kind = .text(content)
            } else if layer.isContainer, !layer.isArtboard {
                return
            } else if layer.style.fills.isEmpty {
                layer.style.fills = [Fill(color)]
            } else {
                layer.style.fills[0].color = color
                layer.style.fills[0].gradient = nil
                layer.style.fills[0].isEnabled = true
            }
        }
    }
}
