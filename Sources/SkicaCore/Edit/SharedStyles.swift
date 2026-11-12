import Foundation

extension Layer {
    /// The shared-style content this layer has now, comparable with a shared style's.
    public var styleContent: SharedStyle.Content {
        if let text = textContent { return .text(text.leadingStyle, alignment: text.alignment) }
        return .layer(style)
    }

    /// Takes on a shared style's look (and keeps the link).
    mutating func adopt(_ shared: SharedStyle) {
        sharedStyleID = shared.id
        switch shared.content {
        case .layer(let style):
            if textContent == nil { self.style = style }
        case .text(let textStyle, let alignment):
            guard var content = textContent else { return }
            content.updateStyles { $0 = textStyle }
            content.alignment = alignment
            kind = .text(content)
        }
    }
}

extension Document {
    /// Layers linked to a shared style that were changed by hand since.
    public func isOutOfSync(_ id: LayerID) -> Bool {
        guard let layer = layers[id], let styleID = layer.sharedStyleID, let shared = assets.sharedStyle(styleID) else { return false }
        return layer.styleContent != shared.content
    }

    public func layers(using styleID: SharedStyleID) -> [LayerID] {
        layers.values.filter { $0.sharedStyleID == styleID }.map(\.id)
    }
}

extension Transaction {
    /// Makes a shared style from a layer's look (text style for text layers) and links the layer.
    @discardableResult
    public mutating func createSharedStyle(from id: LayerID, name: String) -> SharedStyleID? {
        guard let layer = document.layers[id] else { return nil }
        let shared = SharedStyle(name: name, content: layer.styleContent)
        updateAssets { $0.sharedStyles.append(shared) }
        update(id) { $0.sharedStyleID = shared.id }
        return shared.id
    }

    /// Gives layers a shared style; text styles only apply to text and layer styles to the rest.
    public mutating func applySharedStyle(_ styleID: SharedStyleID, to ids: [LayerID]) {
        guard let shared = document.assets.sharedStyle(styleID) else { return }
        for id in ids {
            guard let layer = document.layers[id], (layer.textContent != nil) == shared.isTextStyle else { continue }
            update(id) { $0.adopt(shared) }
        }
    }

    /// Changes a shared style to a layer's current look and updates every layer that uses it.
    public mutating func updateSharedStyle(_ styleID: SharedStyleID, from id: LayerID) {
        guard let layer = document.layers[id], let index = document.assets.sharedStyles.firstIndex(where: { $0.id == styleID }) else { return }
        let content = layer.styleContent
        updateAssets { $0.sharedStyles[index].content = content }
        propagate(styleID)
    }

    /// Puts linked layers back to the shared style.
    public mutating func resetToSharedStyle(_ ids: [LayerID]) {
        for id in ids {
            guard let styleID = document.layers[id]?.sharedStyleID, let shared = document.assets.sharedStyle(styleID) else { continue }
            update(id) { $0.adopt(shared) }
        }
    }

    public mutating func detachSharedStyle(_ ids: [LayerID]) {
        for id in ids { update(id) { $0.sharedStyleID = nil } }
    }

    public mutating func renameSharedStyle(_ styleID: SharedStyleID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        updateAssets { assets in
            if let index = assets.sharedStyles.firstIndex(where: { $0.id == styleID }) { assets.sharedStyles[index].name = trimmed }
        }
    }

    /// Removes a shared style; its layers keep their look and lose the link.
    public mutating func deleteSharedStyle(_ styleID: SharedStyleID) {
        detachSharedStyle(document.layers(using: styleID))
        updateAssets { $0.sharedStyles.removeAll { $0.id == styleID } }
    }

    private mutating func propagate(_ styleID: SharedStyleID) {
        guard let shared = document.assets.sharedStyle(styleID) else { return }
        for id in document.layers(using: styleID) { update(id) { $0.adopt(shared) } }
    }

    // MARK: Swatches

    /// Adds a color to the palette (once) and returns its swatch.
    @discardableResult
    public mutating func addSwatch(_ color: Color, name: String? = nil) -> SwatchID {
        if let existing = document.assets.swatches.first(where: { $0.color == color }) { return existing.id }
        let swatch = Swatch(name: name ?? color.hex, color: color)
        updateAssets { $0.swatches.append(swatch) }
        return swatch.id
    }

    public mutating func updateSwatch(_ id: SwatchID, _ body: (inout Swatch) -> Void) {
        updateAssets { assets in
            if let index = assets.swatches.firstIndex(where: { $0.id == id }) { body(&assets.swatches[index]) }
        }
    }

    public mutating func deleteSwatch(_ id: SwatchID) {
        updateAssets { $0.swatches.removeAll { $0.id == id } }
    }
}
