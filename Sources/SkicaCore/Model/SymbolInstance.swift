import Foundation

/// A placed copy of a symbol, with per-instance changes to the master's layers.
public struct SymbolInstance: Codable, Equatable, Sendable {
    public var symbolID: SymbolID
    /// Keyed by the ID of the layer inside the master (or deeper inside nested symbols).
    public var overrides: [LayerID: LayerOverride]

    public init(symbolID: SymbolID, overrides: [LayerID: LayerOverride] = [:]) {
        self.symbolID = symbolID
        self.overrides = overrides
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        symbolID = try container.decode(SymbolID.self, forKey: .symbolID)
        overrides = try container.decode(CodingKeys.overrides, default: [:])
    }
}

/// What an instance changes about one layer of its symbol.
public struct LayerOverride: Codable, Equatable, Sendable {
    /// Replaces the text of a text layer (keeping its first style).
    public var text: String?
    /// Replaces the color of the first fill (or of the text).
    public var color: Color?
    public var isVisible: Bool?
    /// Shows another symbol in place of a nested instance.
    public var symbolID: SymbolID?
    /// Shows another image in an image layer.
    public var imageHash: String?

    public init(text: String? = nil, color: Color? = nil, isVisible: Bool? = nil, symbolID: SymbolID? = nil, imageHash: String? = nil) {
        self.text = text
        self.color = color
        self.isVisible = isVisible
        self.symbolID = symbolID
        self.imageHash = imageHash
    }

    public var isEmpty: Bool {
        text == nil && color == nil && isVisible == nil && symbolID == nil && imageHash == nil
    }

    /// The layer as an instance shows it.
    public func applied(to layer: Layer) -> Layer {
        var layer = layer
        if let isVisible { layer.isVisible = isVisible }
        if let text, var content = layer.textContent {
            let style = content.leadingStyle
            content.runs = [TextRun(text: text, style: style)]
            layer.kind = .text(content)
        }
        if let color {
            if var content = layer.textContent {
                content.updateStyles { $0.color = color }
                layer.kind = .text(content)
            } else if layer.style.fills.isEmpty {
                layer.style.fills = [Fill(color)]
            } else {
                layer.style.fills[0].color = color
                layer.style.fills[0].gradient = nil
            }
        }
        if let symbolID, var instance = layer.symbolInstance {
            instance.symbolID = symbolID
            layer.kind = .symbolInstance(instance)
        }
        if let imageHash, layer.imageHash != nil {
            layer.kind = .image(hash: imageHash)
        }
        return layer
    }
}
