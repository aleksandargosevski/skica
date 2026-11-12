import CoreGraphics
import Foundation

/// Layers an importer builds with frames in page coordinates. `finish` turns them into the
/// document's form: groups get the bounds of their contents and children become relative to
/// their parent.
struct ImportTree {
    var layers: [LayerID: Layer] = [:]
    var images: [String: Data] = [:]

    @discardableResult
    mutating func add(_ layer: Layer, to parent: LayerID?) -> LayerID {
        var layer = layer
        layer.parent = parent
        layers[layer.id] = layer
        if let parent { layers[parent]?.children.append(layer.id) }
        return layer.id
    }

    mutating func addImage(_ data: Data) -> String {
        let hash = ImageData.hash(of: data)
        images[hash] = data
        return hash
    }

    /// Makes frames relative under each root and drops empty groups; returns the roots that remain.
    mutating func finish(_ roots: [LayerID]) -> [LayerID] {
        roots.filter { relativize($0) }
    }

    func clipboard(roots: [LayerID]) -> LayerClipboard {
        LayerClipboard(roots: roots, layers: layers, images: images)
    }

    /// Returns false (and removes the layer) for groups that end up empty.
    private mutating func relativize(_ id: LayerID) -> Bool {
        guard let layer = layers[id] else { return false }
        let kept = layer.children.filter { relativize($0) }
        layers[id]?.children = kept
        if layer.kind == .group || (layer.symbolInstance == nil && layer.isContainer && layer.frame.width == 0 && layer.frame.height == 0) {
            let frames = kept.compactMap { layers[$0]?.frame.cgRect }
            guard let first = frames.first else {
                layers[id] = nil
                return false
            }
            if layer.kind == .group {
                let bounds = frames.dropFirst().reduce(first) { $0.union($1) }
                layers[id]?.frame = Rect(bounds)
            }
        }
        guard let origin = layers[id]?.frame else { return true }
        for child in kept {
            layers[child]?.frame.x -= origin.x
            layers[child]?.frame.y -= origin.y
        }
        return true
    }
}

extension LayerClipboard {
    init(roots: [LayerID], layers: [LayerID: Layer], images: [String: Data]) {
        self.roots = roots
        self.layers = layers
        self.images = images
    }
}

/// Why an import failed, in words for the user.
public enum ImportError: LocalizedError, Equatable {
    case invalid(String)

    public var errorDescription: String? {
        switch self {
        case .invalid(let message): message
        }
    }
}
