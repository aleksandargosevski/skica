import CoreGraphics
import Foundation

/// The clipping shape of a mask layer, in its parent's coordinates (rotation included).
/// Shapes clip to their outline; containers, text and images to their frame.
public enum MaskShape {
    public static func path(of layer: Layer) -> CGPath? {
        let outline: CGPath
        switch layer.kind {
        case .rectangle, .oval, .polygon, .star, .path:
            guard let path = ShapePath.path(for: layer) else { return nil }
            outline = path
        case .line:
            return nil
        case .artboard, .symbolMaster, .symbolInstance, .group, .text, .image:
            outline = CGPath(rect: layer.frame.cgRect, transform: nil)
        }
        var rotation = layer.rotationTransform
        return outline.copy(using: &rotation)
    }

    /// The mask that clips `id`: the nearest mask below it among its siblings.
    public static func mask(clipping id: LayerID, in document: Document) -> LayerID? {
        guard let parent = document.parentRef(of: id) else { return nil }
        let siblings = document.childIDs(of: parent)
        guard let index = siblings.firstIndex(of: id) else { return nil }
        return siblings[..<index].last { sibling in
            guard let layer = document.layers[sibling] else { return false }
            return layer.isMask && layer.isVisible
        }
    }
}
