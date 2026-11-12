import Foundation

/// While drawing inside symbol instances: the overrides that apply, where the symbol's layers go
/// for the instance's size, and how deep the nesting is.
public struct SymbolScope: Sendable {
    public static let root = SymbolScope(overrides: [:], frames: [:], depth: 0)

    /// Symbols nested deeper than this (or in a cycle) are not drawn.
    static let maximumDepth = 8

    public var overrides: [LayerID: LayerOverride]
    /// Frames of the master's layers laid out for the instance's size by their constraints.
    public var frames: [LayerID: Rect]
    public var depth: Int

    /// The layer as it shows here, with any override and instance layout applied.
    public func resolve(_ layer: Layer) -> Layer {
        var resolved = overrides[layer.id]?.applied(to: layer) ?? layer
        if let frame = frames[layer.id] { resolved.frame = frame }
        return resolved
    }

    /// The scope inside an instance of `master` drawn at `size`: its own overrides (those of
    /// outer instances win), and the master's layers placed by their constraints.
    public func entering(_ instance: SymbolInstance, master: Layer, size: CGSizeValue, in document: Document) -> SymbolScope? {
        guard depth < Self.maximumDepth else { return nil }
        var frames: [LayerID: Rect] = [:]
        let masterSize = CGSizeValue(width: master.frame.width, height: master.frame.height)
        if masterSize != size {
            for child in master.children {
                guard let layer = document.layers[child] else { continue }
                frames[child] = layer.constraints.apply(to: layer.frame, from: masterSize, to: size)
            }
        }
        return SymbolScope(overrides: instance.overrides.merging(overrides) { _, outer in outer }, frames: frames, depth: depth + 1)
    }
}
