import CoreGraphics
import Foundation

/// A line shown while something snaps: where edges or centers line up.
public struct SnapGuide: Equatable, Sendable {
    public var start: CGPoint
    public var end: CGPoint

    public init(start: CGPoint, end: CGPoint) {
        self.start = start
        self.end = end
    }
}

/// Snaps boxes and points to the edges and centers of other layers (page coordinates).
public struct Snapper: Sendable {
    public let targets: [CGRect]
    /// The largest distance that still snaps, in page units.
    public let threshold: CGFloat

    public init(targets: [CGRect], threshold: CGFloat) {
        self.targets = targets
        self.threshold = threshold
    }

    /// Snapping targets for moving `ids`: the other layers at the level clicks select (top-level
    /// layers, artboards and what is directly inside them, plus siblings of the moved layers),
    /// within `area` when given. The moved layers and everything inside them are left out.
    public static func targets(for ids: [LayerID], on page: Page, in document: Document, area: CGRect? = nil) -> [CGRect] {
        let moving = Set(ids.flatMap(document.subtree(of:)))
        var candidates = Set<LayerID>()
        for id in page.layers {
            candidates.insert(id)
            if document.layers[id]?.isArtboard == true { document.layers[id]?.children.forEach { candidates.insert($0) } }
        }
        for id in ids {
            if let parent = document.parentRef(of: id) { document.childIDs(of: parent).forEach { candidates.insert($0) } }
            if let parent = document.layers[id]?.parent { candidates.insert(parent) }
        }
        return candidates.compactMap { id in
            guard !moving.contains(id), let layer = document.layers[id], layer.isVisible,
                  let bounds = document.worldBounds(of: id) else { return nil }
            if let area, !area.intersects(bounds) { return nil }
            return bounds
        }
    }

    /// How far to move `box` so one of its edges or its center lines up, and the guides to show.
    public func snap(moving box: CGRect) -> (offset: CGVector, guides: [SnapGuide]) {
        let dx = bestOffset(from: [box.minX, box.midX, box.maxX], to: targets.flatMap { [$0.minX, $0.midX, $0.maxX] })
        let dy = bestOffset(from: [box.minY, box.midY, box.maxY], to: targets.flatMap { [$0.minY, $0.midY, $0.maxY] })
        let snapped = box.offsetBy(dx: dx ?? 0, dy: dy ?? 0)
        return (CGVector(dx: dx ?? 0, dy: dy ?? 0), guides(for: snapped, vertical: dx != nil, horizontal: dy != nil))
    }

    /// Snaps the edges of `box` that are being dragged (-1 the left/top one, 1 the right/bottom
    /// one, 0 none), e.g. while resizing.
    public func snap(edgesOf box: CGRect, movingX: Int, movingY: Int) -> (box: CGRect, guides: [SnapGuide]) {
        var box = box.standardized
        let xs = targets.flatMap { [$0.minX, $0.midX, $0.maxX] }
        let ys = targets.flatMap { [$0.minY, $0.midY, $0.maxY] }
        var snappedX = false
        var snappedY = false
        if movingX != 0, let dx = bestOffset(from: [movingX < 0 ? box.minX : box.maxX], to: xs) {
            if movingX < 0 { box.origin.x += dx; box.size.width -= dx } else { box.size.width += dx }
            snappedX = true
        }
        if movingY != 0, let dy = bestOffset(from: [movingY < 0 ? box.minY : box.maxY], to: ys) {
            if movingY < 0 { box.origin.y += dy; box.size.height -= dy } else { box.size.height += dy }
            snappedY = true
        }
        return (box, guides(for: box, vertical: snappedX, horizontal: snappedY))
    }

    /// Snaps a point (e.g. the corner being drawn) to edges and centers.
    public func snap(point: CGPoint) -> (point: CGPoint, guides: [SnapGuide]) {
        let dx = bestOffset(from: [point.x], to: targets.flatMap { [$0.minX, $0.midX, $0.maxX] })
        let dy = bestOffset(from: [point.y], to: targets.flatMap { [$0.minY, $0.midY, $0.maxY] })
        let snapped = CGPoint(x: point.x + (dx ?? 0), y: point.y + (dy ?? 0))
        let box = CGRect(origin: snapped, size: .zero)
        return (snapped, guides(for: box, vertical: dx != nil, horizontal: dy != nil))
    }

    /// The smallest move (within the threshold) that puts one of `values` on one of `targets`.
    private func bestOffset(from values: [CGFloat], to targets: [CGFloat]) -> CGFloat? {
        var best: CGFloat?
        for value in values {
            for target in targets {
                let offset = target - value
                if abs(offset) <= threshold, abs(offset) < abs(best ?? .infinity) { best = offset }
            }
        }
        return best
    }

    /// Lines through every edge or center of `box` that matches a target, spanning both.
    private func guides(for box: CGRect, vertical: Bool, horizontal: Bool) -> [SnapGuide] {
        var result: [SnapGuide] = []
        let tolerance: CGFloat = 0.01
        for target in targets {
            if vertical {
                for x in [box.minX, box.midX, box.maxX] where [target.minX, target.midX, target.maxX].contains(where: { abs($0 - x) < tolerance }) {
                    result.append(SnapGuide(start: CGPoint(x: x, y: min(box.minY, target.minY)), end: CGPoint(x: x, y: max(box.maxY, target.maxY))))
                }
            }
            if horizontal {
                for y in [box.minY, box.midY, box.maxY] where [target.minY, target.midY, target.maxY].contains(where: { abs($0 - y) < tolerance }) {
                    result.append(SnapGuide(start: CGPoint(x: min(box.minX, target.minX), y: y), end: CGPoint(x: max(box.maxX, target.maxX), y: y)))
                }
            }
        }
        return result
    }
}
