import CoreGraphics
import Foundation

/// Copied layers with their contents. Root frames are stored in page coordinates, so pasting
/// into another artboard keeps them where they were on the page.
public struct LayerClipboard: Codable, Equatable, Sendable {
    public static let pasteboardType = "io.github.aleksandargosevski.skica.layers"

    public var roots: [LayerID]
    public var layers: [LayerID: Layer]
    /// Bytes of the images the layers show, so they paste into other documents too.
    public var images: [String: Data] = [:]
    /// Masters of the symbols the layers use (also in `layers`), added to documents without them.
    public var masters: [LayerID] = []

    public init(copying ids: [LayerID], from document: Document) {
        let topmost = document.topmostOnly(ids)
        var layers: [LayerID: Layer] = [:]
        for root in topmost {
            for id in document.subtree(of: root) {
                guard var layer = document.layers[id] else { continue }
                if id == root {
                    let origin = CGPoint(x: layer.frame.x, y: layer.frame.y).applying(document.parentSpace(of: id))
                    layer.frame.x = origin.x
                    layer.frame.y = origin.y
                    layer.parent = nil
                }
                layers[id] = layer
            }
        }
        self.roots = topmost.filter { layers[$0] != nil }
        // The symbols these layers show, including symbols nested in them.
        var pending = layers.values.compactMap { $0.symbolInstance?.symbolID }
        var seenSymbols = Set<SymbolID>()
        while let symbolID = pending.popLast() {
            guard seenSymbols.insert(symbolID).inserted, let master = document.master(of: symbolID), layers[master] == nil else { continue }
            masters.append(master)
            for id in document.subtree(of: master) {
                guard let layer = document.layers[id] else { continue }
                layers[id] = layer
                if let nested = layer.symbolInstance?.symbolID { pending.append(nested) }
            }
        }
        self.layers = layers
        for hash in layers.values.compactMap(\.imageHash) {
            images[hash] = document.images[hash]
        }
    }

    public var isEmpty: Bool { roots.isEmpty }

    enum CodingKeys: String, CodingKey {
        case roots, layers, images, masters
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        roots = try container.decode([LayerID].self, forKey: .roots)
        layers = try container.decode([LayerID: Layer].self, forKey: .layers)
        images = try container.decode(CodingKeys.images, default: [:])
        masters = try container.decode(CodingKeys.masters, default: [])
    }

    public mutating func offset(by delta: CGVector) {
        for root in roots {
            layers[root]?.frame.x += delta.dx
            layers[root]?.frame.y += delta.dy
        }
    }

    /// The subtree under `root` with fresh IDs, parents before children, children lists emptied
    /// (they are rebuilt as the layers are inserted).
    func clonedSubtree(of root: LayerID) -> [Layer] {
        var result: [Layer] = []
        func visit(_ id: LayerID, newParent: LayerID?) {
            guard var layer = layers[id] else { return }
            let children = layer.children
            layer.id = .make()
            layer.parent = newParent
            layer.children = []
            result.append(layer)
            for child in children { visit(child, newParent: layer.id) }
        }
        visit(root, newParent: nil)
        return result
    }

    public func encoded() throws -> Data {
        try JSONEncoder().encode(self)
    }

    public static func decode(_ data: Data) throws -> LayerClipboard {
        try JSONDecoder().decode(LayerClipboard.self, from: data)
    }
}
