import CoreGraphics
import Foundation

/// Point editing: finding segments, splitting them and removing points.
extension VectorPath {
    /// A segment runs from `start` to the next point of its subpath.
    public struct SegmentHit: Equatable, Sendable {
        public var start: PointRef
        /// Where along the segment, 0…1.
        public var t: CGFloat
        public var distance: CGFloat
    }

    /// The segment closest to `point` (in the path's coordinates), if within `tolerance`.
    public func segment(near point: CGPoint, tolerance: CGFloat) -> SegmentHit? {
        var best: SegmentHit?
        for (s, subpath) in subpaths.enumerated() {
            let count = subpath.points.count
            let segments = subpath.isClosed ? count : count - 1
            for index in 0..<max(segments, 0) {
                let curve = self.curve(from: PointRef(subpath: s, index: index))
                // Sampling is plenty precise for picking a spot to click on.
                for step in 0...64 {
                    let t = CGFloat(step) / 64
                    let sample = Self.point(on: curve, at: t)
                    let distance = hypot(sample.x - point.x, sample.y - point.y)
                    if distance <= tolerance, distance < (best?.distance ?? .infinity) {
                        best = SegmentHit(start: PointRef(subpath: s, index: index), t: t, distance: distance)
                    }
                }
            }
        }
        return best
    }

    /// Splits a segment at `t` with a new point that keeps the curve's shape; returns it.
    @discardableResult
    public mutating func insertPoint(on segment: PointRef, at t: CGFloat) -> PointRef? {
        guard subpaths.indices.contains(segment.subpath) else { return nil }
        let count = subpaths[segment.subpath].points.count
        guard segment.index < count else { return nil }
        let nextIndex = (segment.index + 1) % count
        let curve = self.curve(from: segment)
        let isStraight = subpaths[segment.subpath].points[segment.index].curveOut == nil
            && subpaths[segment.subpath].points[nextIndex].curveIn == nil

        // de Casteljau: the two halves of the cubic.
        let (p0, p1, p2, p3) = curve
        let a = Self.lerp(p0, p1, t), b = Self.lerp(p1, p2, t), c = Self.lerp(p2, p3, t)
        let d = Self.lerp(a, b, t), e = Self.lerp(b, c, t)
        let split = Self.lerp(d, e, t)

        var newPoint = PathPoint(split)
        if !isStraight {
            subpaths[segment.subpath].points[segment.index].curveOut = a
            subpaths[segment.subpath].points[nextIndex].curveIn = c
            newPoint = PathPoint(split, curveIn: d, curveOut: e, mode: .asymmetric)
        }
        let insertAt = segment.index + 1
        subpaths[segment.subpath].points.insert(newPoint, at: insertAt)
        return PointRef(subpath: segment.subpath, index: insertAt)
    }

    /// Removes points; subpaths left with fewer than two points disappear.
    public mutating func removePoints(_ refs: Set<PointRef>) {
        for s in subpaths.indices.reversed() {
            let doomed = refs.filter { $0.subpath == s }.map(\.index).sorted(by: >)
            for index in doomed where subpaths[s].points.indices.contains(index) {
                subpaths[s].points.remove(at: index)
            }
            if subpaths[s].points.count < 2 { subpaths.remove(at: s) }
        }
    }

    /// The previous and next point of a point in its subpath (wrapping in closed subpaths).
    public func neighbors(of ref: PointRef) -> (previous: CGPoint?, next: CGPoint?) {
        guard subpaths.indices.contains(ref.subpath) else { return (nil, nil) }
        let points = subpaths[ref.subpath].points
        let closed = subpaths[ref.subpath].isClosed
        let previous = ref.index > 0 ? points[ref.index - 1].point : (closed ? points.last?.point : nil)
        let next = ref.index + 1 < points.count ? points[ref.index + 1].point : (closed ? points.first?.point : nil)
        return (previous, next)
    }

    private func curve(from start: PointRef) -> (CGPoint, CGPoint, CGPoint, CGPoint) {
        let points = subpaths[start.subpath].points
        let a = points[start.index]
        let b = points[(start.index + 1) % points.count]
        if a.curveOut == nil, b.curveIn == nil {
            // A straight segment as an evenly parameterized cubic, so t matches the distance along it.
            return (a.point, Self.lerp(a.point, b.point, 1 / 3), Self.lerp(a.point, b.point, 2 / 3), b.point)
        }
        return (a.point, a.curveOut ?? a.point, b.curveIn ?? b.point, b.point)
    }

    private static func point(on curve: (CGPoint, CGPoint, CGPoint, CGPoint), at t: CGFloat) -> CGPoint {
        let (p0, p1, p2, p3) = curve
        let u = 1 - t
        let x = u * u * u * p0.x + 3 * u * u * t * p1.x + 3 * u * t * t * p2.x + t * t * t * p3.x
        let y = u * u * u * p0.y + 3 * u * u * t * p1.y + 3 * u * t * t * p2.y + t * t * t * p3.y
        return CGPoint(x: x, y: y)
    }

    private static func lerp(_ a: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint {
        CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
    }
}
