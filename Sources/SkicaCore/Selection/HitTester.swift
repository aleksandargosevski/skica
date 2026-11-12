import CoreGraphics
import Foundation

/// Finds layers under a page point. Hidden and locked layers let clicks through, and
/// artboards clip what is inside them.
public struct HitTester {
    public let document: Document
    /// How close (in page units) a click must be to a line or border to hit it.
    public var tolerance: CGFloat

    public init(document: Document, tolerance: CGFloat = 4) {
        self.document = document
        self.tolerance = tolerance
    }

    /// The layers under `point`, from the top-level layer down to the deepest one.
    /// An artboard alone means its empty background was hit.
    public func path(at point: CGPoint, on page: Page) -> [LayerID] {
        for id in page.layers.reversed() where !isMaskedOut(id, at: point) {
            if let path = hit(id, at: point) { return path }
        }
        return []
    }

    /// `point` is in the coordinates of the layer's parent contents.
    private func hit(_ id: LayerID, at point: CGPoint) -> [LayerID]? {
        guard let layer = document.layers[id], layer.isVisible, !layer.isLocked else { return nil }
        let unrotated = layer.rotation == 0 ? point : point.applying(layer.rotationTransform.inverted())
        let frame = layer.frame.cgRect

        switch layer.kind {
        case .artboard, .symbolMaster:
            guard frame.contains(unrotated) else { return nil }
            return [id] + (hitChildren(of: layer, at: unrotated) ?? [])
        case .group:
            return hitChildren(of: layer, at: unrotated).map { [id] + $0 }
        default:
            return hitsShape(layer, at: unrotated) ? [id] : nil
        }
    }

    private func hitChildren(of layer: Layer, at point: CGPoint) -> [LayerID]? {
        let local = CGPoint(x: point.x - layer.frame.x, y: point.y - layer.frame.y)
        for child in layer.children.reversed() where !isMaskedOut(child, at: local) {
            if let path = hit(child, at: local) { return path }
        }
        return nil
    }

    /// A point outside the mask that clips a layer does not reach that layer.
    private func isMaskedOut(_ id: LayerID, at point: CGPoint) -> Bool {
        guard let mask = MaskShape.mask(clipping: id, in: document), let shape = document.layers[mask].flatMap(MaskShape.path(of:)) else {
            return false
        }
        return !shape.contains(point, using: document.layers[mask]?.vectorPath?.fillRule == .evenOdd ? .evenOdd : .winding)
    }

    private func hitsShape(_ layer: Layer, at point: CGPoint) -> Bool {
        let border = layer.style.borders.filter(\.isEnabled).map(\.width).max() ?? 0
        let reach = max(border / 2, 0) + tolerance
        guard layer.frame.cgRect.insetBy(dx: -reach, dy: -reach).contains(point),
              let path = ShapePath.path(for: layer) else { return false }
        // Paths without a fill are only hit on their outline, like lines.
        let interiorCounts = !ShapePath.isOpen(layer.kind) && (layer.vectorPath == nil || layer.style.fills.contains(where: \.isEnabled))
        if interiorCounts, path.contains(point, using: layer.vectorPath?.fillRule == .evenOdd ? .evenOdd : .winding) { return true }
        let outline = path.copy(strokingWithWidth: reach * 2, lineCap: .round, lineJoin: .round, miterLimit: 4)
        return outline.contains(point)
    }
}
