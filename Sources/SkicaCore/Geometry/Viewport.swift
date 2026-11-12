import CoreGraphics

/// Maps between view points (y down, origin top-left of the canvas view) and canvas points.
public struct Viewport: Equatable, Sendable {
    public static let zoomRange: ClosedRange<CGFloat> = 0.01...256
    public static let zoomSteps: [CGFloat] = [0.01, 0.02, 0.03, 0.06, 0.125, 0.25, 0.5, 1, 2, 4, 8, 16, 32, 64, 128, 256]

    /// The canvas point shown at the view's top-left corner.
    public var origin: CGPoint
    public private(set) var zoom: CGFloat

    public init(origin: CGPoint = .zero, zoom: CGFloat = 1) {
        self.origin = origin
        self.zoom = Self.clamp(zoom)
    }

    public func toCanvas(_ point: CGPoint) -> CGPoint {
        CGPoint(x: origin.x + point.x / zoom, y: origin.y + point.y / zoom)
    }

    public func toView(_ point: CGPoint) -> CGPoint {
        CGPoint(x: (point.x - origin.x) * zoom, y: (point.y - origin.y) * zoom)
    }

    public func toCanvas(_ rect: CGRect) -> CGRect {
        CGRect(origin: toCanvas(rect.origin), size: CGSize(width: rect.width / zoom, height: rect.height / zoom))
    }

    public func toView(_ rect: CGRect) -> CGRect {
        CGRect(origin: toView(rect.origin), size: CGSize(width: rect.width * zoom, height: rect.height * zoom))
    }

    /// Changes the zoom while the canvas point under `anchor` (a view point) stays in place.
    public mutating func setZoom(_ newZoom: CGFloat, keeping anchor: CGPoint) {
        let canvasAnchor = toCanvas(anchor)
        zoom = Self.clamp(newZoom)
        origin = CGPoint(x: canvasAnchor.x - anchor.x / zoom, y: canvasAnchor.y - anchor.y / zoom)
    }

    /// Moves the content by `delta` view points, as when dragging it.
    public mutating func pan(by delta: CGVector) {
        origin.x -= delta.dx / zoom
        origin.y -= delta.dy / zoom
    }

    /// Zooms so `rect` fills the view minus `padding`, centered.
    public mutating func fit(_ rect: CGRect, in size: CGSize, padding: CGFloat = 48, maxZoom: CGFloat = zoomRange.upperBound) {
        guard size.width > 0, size.height > 0 else { return }
        let available = CGSize(width: max(size.width - padding * 2, 1), height: max(size.height - padding * 2, 1))
        let fitting = min(available.width / max(rect.width, 1), available.height / max(rect.height, 1))
        zoom = Self.clamp(min(fitting, maxZoom))
        center(on: CGPoint(x: rect.midX, y: rect.midY), in: size)
    }

    public mutating func center(on point: CGPoint, in size: CGSize) {
        origin = CGPoint(x: point.x - size.width / 2 / zoom, y: point.y - size.height / 2 / zoom)
    }

    public static func step(above zoom: CGFloat) -> CGFloat {
        zoomSteps.first { $0 > zoom * 1.001 } ?? zoomRange.upperBound
    }

    public static func step(below zoom: CGFloat) -> CGFloat {
        zoomSteps.last { $0 < zoom / 1.001 } ?? zoomRange.lowerBound
    }

    private static func clamp(_ zoom: CGFloat) -> CGFloat {
        min(max(zoom, zoomRange.lowerBound), zoomRange.upperBound)
    }
}
