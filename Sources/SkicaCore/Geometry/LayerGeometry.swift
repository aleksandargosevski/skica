import CoreGraphics
import Foundation

extension Layer {
    /// Rotation around the frame's center, in the parent's coordinates.
    public var rotationTransform: CGAffineTransform {
        guard rotation != 0 else { return .identity }
        let frame = frame.cgRect
        return CGAffineTransform(translationX: -frame.midX, y: -frame.midY)
            .concatenating(CGAffineTransform(rotationAngle: rotation * .pi / 180))
            .concatenating(CGAffineTransform(translationX: frame.midX, y: frame.midY))
    }
}

/// World coordinates are the page's coordinates, where top-level frames live.
extension Document {
    /// Maps the coordinates a layer's frame is expressed in (its parent's contents) to the page.
    public func parentSpace(of id: LayerID) -> CGAffineTransform {
        guard let parent = layers[id]?.parent else { return .identity }
        return contentsTransform(of: parent)
    }

    /// Maps a container's children coordinates to the page.
    public func contentsTransform(of id: LayerID) -> CGAffineTransform {
        guard let layer = layers[id] else { return .identity }
        return CGAffineTransform(translationX: layer.frame.x, y: layer.frame.y)
            .concatenating(layer.rotationTransform)
            .concatenating(parentSpace(of: id))
    }

    /// Maps the layer's (unrotated) frame coordinates to the page, including its rotation.
    public func worldTransform(of id: LayerID) -> CGAffineTransform {
        guard let layer = layers[id] else { return .identity }
        return layer.rotationTransform.concatenating(parentSpace(of: id))
    }

    /// The four corners of the layer's frame on the page, clockwise from the top-left.
    public func worldCorners(of id: LayerID) -> [CGPoint] {
        guard let layer = layers[id] else { return [] }
        let frame = layer.frame.cgRect
        let transform = worldTransform(of: id)
        return [
            CGPoint(x: frame.minX, y: frame.minY), CGPoint(x: frame.maxX, y: frame.minY),
            CGPoint(x: frame.maxX, y: frame.maxY), CGPoint(x: frame.minX, y: frame.maxY),
        ].map { $0.applying(transform) }
    }

    /// Axis-aligned bounds of the layer's frame on the page.
    public func worldBounds(of id: LayerID) -> CGRect? {
        guard let layer = layers[id] else { return nil }
        return layer.frame.cgRect.applying(worldTransform(of: id))
    }

    public func worldBounds(of ids: [LayerID]) -> CGRect? {
        ids.compactMap(worldBounds(of:)).reduce(nil) { union, rect in union?.union(rect) ?? rect }
    }

    /// The layer's path on the page, including rotation.
    public func worldPath(of id: LayerID) -> CGPath? {
        guard let layer = layers[id], let path = ShapePath.path(for: layer) else { return nil }
        var transform = worldTransform(of: id)
        return path.copy(using: &transform)
    }

    /// A page point in the coordinates a layer's frame is expressed in.
    public func pointInParentSpace(_ point: CGPoint, of id: LayerID) -> CGPoint {
        point.applying(parentSpace(of: id).inverted())
    }

    /// A page offset in the coordinates a layer's frame is expressed in.
    public func vectorInParentSpace(_ vector: CGVector, of id: LayerID) -> CGVector {
        let inverse = parentSpace(of: id).inverted()
        let origin = CGPoint.zero.applying(inverse)
        let end = CGPoint(x: vector.dx, y: vector.dy).applying(inverse)
        return CGVector(dx: end.x - origin.x, dy: end.y - origin.y)
    }
}
