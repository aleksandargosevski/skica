import CoreGraphics
import Foundation

/// What a drag on the canvas does.
public enum Tool: String, CaseIterable, Sendable {
    case select, rectangle, oval, line, polygon, star, pen, text, artboard

    public var title: String {
        switch self {
        case .select: "Select"
        case .rectangle: "Rectangle"
        case .oval: "Oval"
        case .line: "Line"
        case .polygon: "Polygon"
        case .star: "Star"
        case .pen: "Pen"
        case .text: "Text"
        case .artboard: "Artboard"
        }
    }

    /// Size used when a shape is made with a click or the keyboard instead of a drag.
    public var defaultSize: CGSize {
        switch self {
        case .artboard: CGSize(width: 390, height: 844)
        case .line: CGSize(width: 100, height: 0)
        case .text, .pen: .zero
        default: CGSize(width: 100, height: 100)
        }
    }

    public static let defaultFill = Color(red: 0xD8, green: 0xD8, blue: 0xD8)
    public static let defaultBorder = Color(red: 0x97, green: 0x97, blue: 0x97)

    /// A new layer for this tool; `from` and `to` are the drag's start and end in the parent's
    /// coordinates, which also give a line its direction.
    public func makeLayer(from start: CGPoint, to end: CGPoint) -> Layer? {
        let frame = Rect(CGRect(
            x: min(start.x, end.x), y: min(start.y, end.y),
            width: abs(end.x - start.x), height: abs(end.y - start.y)
        ))
        let shapeStyle = Style(fills: [Fill(Self.defaultFill)], borders: [Border(Self.defaultBorder)])
        switch self {
        case .select, .pen:
            return nil
        case .rectangle:
            return Layer(name: title, kind: .rectangle(cornerRadius: 0), frame: frame, style: shapeStyle)
        case .oval:
            return Layer(name: title, kind: .oval, frame: frame, style: shapeStyle)
        case .polygon:
            return Layer(name: title, kind: .polygon(sides: 5), frame: frame, style: shapeStyle)
        case .star:
            return Layer(name: title, kind: .star(points: 5, innerRadius: 0.5), frame: frame, style: shapeStyle)
        case .artboard:
            return Layer(name: title, kind: .artboard, frame: frame, style: Style(fills: [Fill(.white)]))
        case .text:
            // A click makes text that grows sideways; a drag sets a width to wrap at.
            let sizing: TextContent.Sizing = frame.width >= 4 ? .autoHeight : .autoWidth
            return Layer(name: title, kind: .text(TextContent("", sizing: sizing)), frame: frame)
        case .line:
            let from = UnitPoint(x: end.x >= start.x ? 0 : 1, y: end.y >= start.y ? 0 : 1)
            let to = UnitPoint(x: 1 - from.x, y: 1 - from.y)
            return Layer(name: title, kind: .line(from: from, to: to), frame: frame, style: Style(borders: [Border(Self.defaultBorder)]))
        }
    }
}
