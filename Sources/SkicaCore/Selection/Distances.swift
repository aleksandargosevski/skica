import CoreGraphics
import Foundation

/// The distances shown while holding ⌥: from the selection to the layer under the pointer.
public struct Distances: Equatable, Sendable {
    public struct Line: Equatable, Sendable {
        public var start: CGPoint
        public var end: CGPoint
        public var value: CGFloat
    }

    /// Measured lines, each with its length.
    public var lines: [Line] = []
    /// Dashed lines that carry a measurement over to the target when the boxes do not face each other.
    public var extensions: [SnapGuide] = []

    /// Layers apart on an axis show the gap between them; layers that overlap (or one inside the
    /// other) show how far their edges are from each other.
    public init(from selection: CGRect, to target: CGRect) {
        let a = selection.standardized, b = target.standardized
        let apartX = a.maxX <= b.minX || b.maxX <= a.minX
        let apartY = a.maxY <= b.minY || b.maxY <= a.minY

        if apartX {
            let y = apartY ? a.midY : Self.middle(of: a.minY...a.maxY, b.minY...b.maxY)
            let (from, to) = a.maxX <= b.minX ? (a.maxX, b.minX) : (a.minX, b.maxX)
            addHorizontal(from: from, to: to, y: y, target: b)
        }
        if apartY {
            let x = apartX ? a.midX : Self.middle(of: a.minX...a.maxX, b.minX...b.maxX)
            let (from, to) = a.maxY <= b.minY ? (a.maxY, b.minY) : (a.minY, b.maxY)
            addVertical(from: from, to: to, x: x, target: b)
        }
        if !apartX, !apartY {
            addHorizontal(from: a.minX, to: b.minX, y: a.midY, target: b)
            addHorizontal(from: a.maxX, to: b.maxX, y: a.midY, target: b)
            addVertical(from: a.minY, to: b.minY, x: a.midX, target: b)
            addVertical(from: a.maxY, to: b.maxY, x: a.midX, target: b)
        }
    }

    public var isEmpty: Bool { lines.isEmpty }

    /// What to measure the selection against: the hovered layer, or the selection's container
    /// when the pointer is over the selection itself or over nothing.
    public static func target(for selection: [LayerID], hovered: LayerID?, in document: Document) -> LayerID? {
        guard let first = selection.first else { return nil }
        if let hovered, !selection.contains(hovered), !selection.contains(where: { document.isAncestor($0, of: hovered) }) {
            return hovered
        }
        return document.layers[first]?.parent
    }

    /// A line from the selection's edge at `from` to the target's edge at `to`.
    private mutating func addHorizontal(from: CGFloat, to: CGFloat, y: CGFloat, target: CGRect) {
        guard from != to else { return }
        lines.append(Line(start: CGPoint(x: from, y: y), end: CGPoint(x: to, y: y), value: abs(to - from)))
        let reach = min(max(y, target.minY), target.maxY)
        if reach != y { extensions.append(SnapGuide(start: CGPoint(x: to, y: y), end: CGPoint(x: to, y: reach))) }
    }

    private mutating func addVertical(from: CGFloat, to: CGFloat, x: CGFloat, target: CGRect) {
        guard from != to else { return }
        lines.append(Line(start: CGPoint(x: x, y: from), end: CGPoint(x: x, y: to), value: abs(to - from)))
        let reach = min(max(x, target.minX), target.maxX)
        if reach != x { extensions.append(SnapGuide(start: CGPoint(x: x, y: to), end: CGPoint(x: reach, y: to))) }
    }

    private static func middle(of first: ClosedRange<CGFloat>, _ second: ClosedRange<CGFloat>) -> CGFloat {
        (max(first.lowerBound, second.lowerBound) + min(first.upperBound, second.upperBound)) / 2
    }
}
