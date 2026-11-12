import CoreGraphics
import Foundation

/// A free-form shape: one or more subpaths of points with optional curve handles.
/// Points are in the layer's own coordinates (0,0 is the frame's top-left), and edits keep the
/// frame wrapped around the points (see `Transaction.fitPaths`).
public struct VectorPath: Codable, Equatable, Sendable {
    public enum FillRule: String, Codable, CaseIterable, Sendable {
        case nonZero, evenOdd
    }

    public var subpaths: [Subpath]
    public var fillRule: FillRule

    public init(subpaths: [Subpath], fillRule: FillRule = .nonZero) {
        self.subpaths = subpaths
        self.fillRule = fillRule
    }

    public var isEmpty: Bool { subpaths.allSatisfy { $0.points.isEmpty } }

    /// Every point, for counting and cycling through them.
    public var pointRefs: [PointRef] {
        subpaths.indices.flatMap { subpath in subpaths[subpath].points.indices.map { PointRef(subpath: subpath, index: $0) } }
    }

    public subscript(ref: PointRef) -> PathPoint? {
        get {
            guard subpaths.indices.contains(ref.subpath), subpaths[ref.subpath].points.indices.contains(ref.index) else { return nil }
            return subpaths[ref.subpath].points[ref.index]
        }
        set {
            guard let newValue, subpaths.indices.contains(ref.subpath), subpaths[ref.subpath].points.indices.contains(ref.index) else { return }
            subpaths[ref.subpath].points[ref.index] = newValue
        }
    }

    /// The path as Core Graphics draws it, moved by `offset` (the frame's origin).
    public func cgPath(offset: CGPoint = .zero) -> CGPath {
        let path = CGMutablePath()
        let shift = { (point: CGPoint) in CGPoint(x: point.x + offset.x, y: point.y + offset.y) }
        for subpath in subpaths where !subpath.points.isEmpty {
            let points = subpath.points
            path.move(to: shift(points[0].point))
            let segments = subpath.isClosed ? points.count : points.count - 1
            for index in 0..<max(segments, 0) {
                let start = points[index]
                let end = points[(index + 1) % points.count]
                if start.curveOut == nil, end.curveIn == nil {
                    path.addLine(to: shift(end.point))
                } else {
                    path.addCurve(to: shift(end.point), control1: shift(start.curveOut ?? start.point), control2: shift(end.curveIn ?? end.point))
                }
            }
            if subpath.isClosed { path.closeSubpath() }
        }
        return path
    }

    /// Reads any Core Graphics path (curves become cubic; a closing point that repeats the start
    /// is merged into it).
    public init(_ path: CGPath, fillRule: FillRule = .nonZero) {
        var subpaths: [Subpath] = []
        var current: Subpath?
        func finish(closed: Bool) {
            guard var subpath = current, !subpath.points.isEmpty else { current = nil; return }
            if closed {
                subpath.isClosed = true
                if subpath.points.count > 1, let first = subpath.points.first, let last = subpath.points.last,
                   hypot(first.point.x - last.point.x, first.point.y - last.point.y) < 0.001 {
                    subpath.points[0].curveIn = last.curveIn
                    subpath.points.removeLast()
                }
            }
            subpaths.append(subpath)
            current = nil
        }
        path.applyWithBlock { element in
            let points = element.pointee.points
            switch element.pointee.type {
            case .moveToPoint:
                finish(closed: false)
                current = Subpath(points: [PathPoint(points[0])])
            case .addLineToPoint:
                current?.points.append(PathPoint(points[0]))
            case .addQuadCurveToPoint:
                guard let last = current?.points.last?.point else { break }
                let control = points[0]
                let end = points[1]
                let c1 = CGPoint(x: last.x + 2 / 3 * (control.x - last.x), y: last.y + 2 / 3 * (control.y - last.y))
                let c2 = CGPoint(x: end.x + 2 / 3 * (control.x - end.x), y: end.y + 2 / 3 * (control.y - end.y))
                guard var subpath = current, !subpath.points.isEmpty else { break }
                subpath.points[subpath.points.count - 1].curveOut = c1
                subpath.points.append(PathPoint(end, curveIn: c2))
                current = subpath
            case .addCurveToPoint:
                guard var subpath = current, !subpath.points.isEmpty else { break }
                subpath.points[subpath.points.count - 1].curveOut = points[0]
                subpath.points.append(PathPoint(points[2], curveIn: points[1]))
                current = subpath
            case .closeSubpath:
                finish(closed: true)
            @unknown default:
                break
            }
        }
        finish(closed: false)
        self.init(subpaths: subpaths.map(\.withInferredModes), fillRule: fillRule)
    }

    /// The same path with every point moved by `transform`.
    public func applying(_ transform: CGAffineTransform) -> VectorPath {
        var copy = self
        for s in copy.subpaths.indices {
            for p in copy.subpaths[s].points.indices {
                copy.subpaths[s].points[p] = copy.subpaths[s].points[p].applying(transform)
            }
        }
        return copy
    }

    /// Bounds of the drawn path (not of its handles).
    public var bounds: CGRect {
        let path = cgPath()
        return path.isEmpty ? .zero : path.boundingBoxOfPath
    }
}

public struct Subpath: Codable, Equatable, Sendable {
    public var points: [PathPoint]
    public var isClosed: Bool

    public init(points: [PathPoint], isClosed: Bool = false) {
        self.points = points
        self.isClosed = isClosed
    }

    var withInferredModes: Subpath {
        var copy = self
        for index in copy.points.indices { copy.points[index].mode = copy.points[index].inferredMode }
        return copy
    }
}

/// Which point of which subpath.
public struct PointRef: Hashable, Sendable, Comparable {
    public var subpath: Int
    public var index: Int

    public init(subpath: Int, index: Int) {
        self.subpath = subpath
        self.index = index
    }

    public static func < (lhs: PointRef, rhs: PointRef) -> Bool {
        lhs.subpath != rhs.subpath ? lhs.subpath < rhs.subpath : lhs.index < rhs.index
    }
}

public struct PathPoint: Codable, Equatable, Sendable {
    /// How the two handles of a point move together.
    public enum Mode: String, Codable, CaseIterable, Sendable {
        /// No handles: a sharp corner.
        case straight
        /// Handles opposite each other at the same length.
        case mirrored
        /// Handles opposite each other, each with its own length.
        case asymmetric
        /// Handles move independently.
        case disconnected

        public var title: String {
            switch self {
            case .straight: "Straight"
            case .mirrored: "Mirrored"
            case .asymmetric: "Asymmetric"
            case .disconnected: "Disconnected"
            }
        }
    }

    public var point: CGPoint
    /// The handle toward the previous point; nil for a straight segment on that side.
    public var curveIn: CGPoint?
    /// The handle toward the next point.
    public var curveOut: CGPoint?
    public var mode: Mode

    public init(_ point: CGPoint, curveIn: CGPoint? = nil, curveOut: CGPoint? = nil, mode: Mode? = nil) {
        self.point = point
        self.curveIn = curveIn
        self.curveOut = curveOut
        self.mode = .straight
        self.mode = mode ?? inferredMode
    }

    /// Guesses the mode from the handles, for paths read from elsewhere.
    var inferredMode: Mode {
        guard let curveIn, let curveOut else { return curveIn == nil && curveOut == nil ? .straight : .disconnected }
        let a = CGVector(dx: point.x - curveIn.x, dy: point.y - curveIn.y)
        let b = CGVector(dx: curveOut.x - point.x, dy: curveOut.y - point.y)
        let lengthA = hypot(a.dx, a.dy)
        let lengthB = hypot(b.dx, b.dy)
        guard lengthA > 0.001, lengthB > 0.001 else { return .disconnected }
        let cross = (a.dx * b.dy - a.dy * b.dx) / (lengthA * lengthB)
        guard abs(cross) < 0.01 else { return .disconnected }
        return abs(lengthA - lengthB) < 0.01 ? .mirrored : .asymmetric
    }

    public func applying(_ transform: CGAffineTransform) -> PathPoint {
        var copy = self
        copy.point = point.applying(transform)
        copy.curveIn = curveIn?.applying(transform)
        copy.curveOut = curveOut?.applying(transform)
        return copy
    }

    /// Moves one handle and keeps the other in step according to the mode.
    public mutating func setHandle(out: Bool, to handle: CGPoint) {
        if out { curveOut = handle } else { curveIn = handle }
        let other = out ? curveIn : curveOut
        let vector = CGVector(dx: point.x - handle.x, dy: point.y - handle.y)
        switch mode {
        case .straight, .disconnected:
            if mode == .straight { mode = .disconnected }
            return
        case .mirrored:
            let mirrored = CGPoint(x: point.x + vector.dx, y: point.y + vector.dy)
            if out { curveIn = mirrored } else { curveOut = mirrored }
        case .asymmetric:
            let length = other.map { hypot($0.x - point.x, $0.y - point.y) } ?? hypot(vector.dx, vector.dy)
            let total = max(hypot(vector.dx, vector.dy), 0.0001)
            let opposite = CGPoint(x: point.x + vector.dx / total * length, y: point.y + vector.dy / total * length)
            if out { curveIn = opposite } else { curveOut = opposite }
        }
    }

    /// Changes the mode, adding or straightening handles. `neighbors` (previous and next point)
    /// set the direction of new handles.
    public mutating func setMode(_ newMode: Mode, previous: CGPoint?, next: CGPoint?) {
        mode = newMode
        switch newMode {
        case .straight:
            curveIn = nil
            curveOut = nil
        case .mirrored, .asymmetric:
            // Handles along the line between the neighbors, a third of the way to each.
            let before = previous ?? CGPoint(x: point.x - 30, y: point.y)
            let after = next ?? CGPoint(x: point.x + 30, y: point.y)
            var direction = CGVector(dx: after.x - before.x, dy: after.y - before.y)
            let length = max(hypot(direction.dx, direction.dy), 0.0001)
            direction = CGVector(dx: direction.dx / length, dy: direction.dy / length)
            let reachIn = newMode == .mirrored || curveIn == nil
                ? hypot(after.x - before.x, after.y - before.y) / 6
                : hypot(curveIn!.x - point.x, curveIn!.y - point.y)
            let reachOut = newMode == .mirrored ? reachIn : (curveOut.map { hypot($0.x - point.x, $0.y - point.y) } ?? reachIn)
            curveIn = CGPoint(x: point.x - direction.dx * reachIn, y: point.y - direction.dy * reachIn)
            curveOut = CGPoint(x: point.x + direction.dx * reachOut, y: point.y + direction.dy * reachOut)
        case .disconnected:
            break
        }
    }
}

/// A point stored as `{"x":…,"y":…}` in JSON.
public struct Point: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double

    public init(_ point: CGPoint) {
        x = point.x
        y = point.y
    }

    public var cgPoint: CGPoint { CGPoint(x: x, y: y) }
}

extension PathPoint {
    init(_ point: CGPoint, curveIn: CGPoint) {
        self.init(point, curveIn: curveIn, curveOut: nil)
    }

    enum CodingKeys: String, CodingKey {
        case point, curveIn, curveOut, mode
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        point = try container.decode(Point.self, forKey: .point).cgPoint
        curveIn = try container.decodeIfPresent(Point.self, forKey: .curveIn)?.cgPoint
        curveOut = try container.decodeIfPresent(Point.self, forKey: .curveOut)?.cgPoint
        mode = .straight
        mode = try container.decodeIfPresent(Mode.self, forKey: .mode) ?? inferredMode
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Point(point), forKey: .point)
        try container.encodeIfPresent(curveIn.map(Point.init), forKey: .curveIn)
        try container.encodeIfPresent(curveOut.map(Point.init), forKey: .curveOut)
        try container.encode(mode, forKey: .mode)
    }
}
