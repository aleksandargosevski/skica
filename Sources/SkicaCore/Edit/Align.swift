import CoreGraphics
import Foundation

public enum AlignEdge: String, CaseIterable, Sendable {
    case left, horizontalCenter, right, top, verticalCenter, bottom
}

extension Transaction {
    /// Lines up layers along an edge or center: of their combined bounds, or of their parent
    /// (the artboard) when there is only one layer.
    public mutating func align(_ ids: [LayerID], _ edge: AlignEdge) {
        let ids = document.topmostOnly(ids)
        let reference: CGRect?
        if ids.count == 1, let parent = document.layers[ids[0]]?.parent {
            reference = document.worldBounds(of: parent)
        } else {
            reference = document.worldBounds(of: ids)
        }
        guard let target = reference else { return }
        for id in ids {
            guard let bounds = document.worldBounds(of: id) else { continue }
            var delta = CGVector.zero
            switch edge {
            case .left: delta.dx = target.minX - bounds.minX
            case .horizontalCenter: delta.dx = (target.midX - bounds.midX).rounded()
            case .right: delta.dx = target.maxX - bounds.maxX
            case .top: delta.dy = target.minY - bounds.minY
            case .verticalCenter: delta.dy = (target.midY - bounds.midY).rounded()
            case .bottom: delta.dy = target.maxY - bounds.maxY
            }
            move([id], by: delta)
        }
    }

    /// Spaces layers along an axis: evenly between the outermost ones (three or more layers), or,
    /// with `spacing`, exactly that far apart starting from the first one (two or more).
    public mutating func distribute(_ ids: [LayerID], horizontally: Bool, spacing: Double? = nil) {
        let ids = document.topmostOnly(ids)
        let boxes = ids.compactMap { id in document.worldBounds(of: id).map { (id, $0) } }
        guard boxes.count >= (spacing == nil ? 3 : 2) else { return }
        let sorted = boxes.sorted { horizontally ? $0.1.minX < $1.1.minX : $0.1.minY < $1.1.minY }
        let total = sorted.reduce(0) { $0 + (horizontally ? $1.1.width : $1.1.height) }
        let start = horizontally ? sorted.first!.1.minX : sorted.first!.1.minY
        let end = horizontally ? sorted.last!.1.maxX : sorted.last!.1.maxY
        let gap = spacing.map { CGFloat($0) } ?? (end - start - total) / CGFloat(sorted.count - 1)
        var position = start
        for (id, box) in sorted {
            let current = horizontally ? box.minX : box.minY
            let delta = (position - current).rounded()
            move([id], by: horizontally ? CGVector(dx: delta, dy: 0) : CGVector(dx: 0, dy: delta))
            position += (horizontally ? box.width : box.height) + gap
        }
    }
}

extension Document {
    /// The space between neighbouring layers along an axis when it is the same everywhere
    /// (rounded to a tenth); nil when the gaps differ, layers overlap along the axis, or there
    /// are fewer than two layers.
    public func uniformSpacing(of ids: [LayerID], horizontally: Bool) -> Double? {
        let boxes = topmostOnly(ids).compactMap { worldBounds(of: $0) }
            .sorted { horizontally ? $0.minX < $1.minX : $0.minY < $1.minY }
        guard boxes.count >= 2 else { return nil }
        let gaps = zip(boxes, boxes.dropFirst()).map { a, b in
            ((horizontally ? b.minX - a.maxX : b.minY - a.maxY) * 10).rounded() / 10
        }
        return Set(gaps).count == 1 && gaps[0] >= 0 ? gaps[0] : nil
    }
}
