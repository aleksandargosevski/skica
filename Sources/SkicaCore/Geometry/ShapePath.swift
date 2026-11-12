import CoreGraphics
import Foundation

/// The outlines of shape layers, shared by rendering, hit testing and (later) export.
public enum ShapePath {
    /// The layer's outline in its parent's coordinates, without rotation; nil for groups.
    public static func path(for layer: Layer) -> CGPath? {
        let frame = layer.frame.cgRect
        switch layer.kind {
        case .artboard, .symbolMaster, .symbolInstance:
            return CGPath(rect: frame, transform: nil)
        case .group:
            return nil
        case .rectangle(let radius):
            return roundedRect(frame, radius: radius)
        case .oval:
            return CGPath(ellipseIn: frame, transform: nil)
        case .line(let from, let to):
            let path = CGMutablePath()
            path.move(to: point(from, in: frame))
            path.addLine(to: point(to, in: frame))
            return path
        case .polygon(let sides):
            return polygon(in: frame, sides: sides)
        case .star(let points, let innerRadius):
            return star(in: frame, points: points, innerRadius: innerRadius)
        case .text, .image:
            return CGPath(rect: frame, transform: nil)
        case .path(let vector):
            return vector.cgPath(offset: frame.origin)
        }
    }

    /// Lines are stroked only; fills never apply to them.
    public static func isOpen(_ kind: LayerKind) -> Bool {
        if case .line = kind { return true }
        return false
    }

    public static func point(_ unit: UnitPoint, in frame: CGRect) -> CGPoint {
        CGPoint(x: frame.minX + unit.x * frame.width, y: frame.minY + unit.y * frame.height)
    }

    static func roundedRect(_ rect: CGRect, radius: Double) -> CGPath {
        let radius = min(max(radius, 0), min(rect.width, rect.height) / 2)
        guard radius > 0 else { return CGPath(rect: rect, transform: nil) }
        return CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    }

    /// A regular polygon inscribed in the frame's ellipse, with its first corner at the top.
    static func polygon(in rect: CGRect, sides: Int) -> CGPath {
        let count = max(sides, 3)
        let corners = (0..<count).map { index in
            ellipsePoint(in: rect, angle: Double(index) / Double(count) * 2 * .pi, scale: 1)
        }
        return closedPath(corners)
    }

    static func star(in rect: CGRect, points: Int, innerRadius: Double) -> CGPath {
        let count = max(points, 3)
        let inner = min(max(innerRadius, 0.01), 1)
        let corners = (0..<count * 2).map { index in
            ellipsePoint(in: rect, angle: Double(index) / Double(count * 2) * 2 * .pi, scale: index.isMultiple(of: 2) ? 1 : inner)
        }
        return closedPath(corners)
    }

    private static func ellipsePoint(in rect: CGRect, angle: Double, scale: Double) -> CGPoint {
        let start = -Double.pi / 2
        return CGPoint(
            x: rect.midX + cos(start + angle) * rect.width / 2 * scale,
            y: rect.midY + sin(start + angle) * rect.height / 2 * scale
        )
    }

    private static func closedPath(_ points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        path.addLines(between: points)
        path.closeSubpath()
        return path
    }
}
