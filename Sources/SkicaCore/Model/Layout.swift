import Foundation

/// How a layer follows its artboard (or symbol) when that changes size, per axis.
public struct Constraints: Codable, Equatable, Hashable, Sendable {
    public enum Pin: String, Codable, CaseIterable, Sendable {
        /// Keeps its distance to the left (or top) edge and its size.
        case start
        /// Keeps its distance to the right (or bottom) edge and its size.
        case end
        /// Keeps both distances; the size stretches.
        case both
        /// Stays centered; keeps its size.
        case center
        /// Position and size scale with the parent.
        case scale
    }

    public var horizontal: Pin
    public var vertical: Pin

    public init(horizontal: Pin = .start, vertical: Pin = .start) {
        self.horizontal = horizontal
        self.vertical = vertical
    }

    /// The frame for a parent resized from `old` to `new` (sizes of the parent).
    public func apply(to frame: Rect, from old: CGSizeValue, to new: CGSizeValue) -> Rect {
        let (x, width) = Self.axis(horizontal, position: frame.x, length: frame.width, old: old.width, new: new.width)
        let (y, height) = Self.axis(vertical, position: frame.y, length: frame.height, old: old.height, new: new.height)
        return Rect(x: x, y: y, width: width, height: height)
    }

    private static func axis(_ pin: Pin, position: Double, length: Double, old: Double, new: Double) -> (Double, Double) {
        let growth = new - old
        switch pin {
        case .start: return (position, length)
        case .end: return (position + growth, length)
        case .both: return (position, max(length + growth, 0))
        case .center: return (position + growth / 2, length)
        case .scale:
            let factor = old > 0 ? new / old : 1
            return (position * factor, length * factor)
        }
    }
}

/// A width and height pair stored without Core Graphics, for layout math.
public struct CGSizeValue: Equatable, Sendable {
    public var width: Double
    public var height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }
}

/// Lays out a container's children in a row or a column (like Figma's auto layout).
public struct StackLayout: Codable, Equatable, Sendable {
    public enum Direction: String, Codable, CaseIterable, Sendable {
        case horizontal, vertical
    }

    /// Where children sit across the stack's direction.
    public enum Alignment: String, Codable, CaseIterable, Sendable {
        case start, center, end
    }

    public var direction: Direction
    /// Space between children.
    public var spacing: Double
    public var padding: Insets
    public var alignment: Alignment
    /// Shrinks or grows the container to fit its children (plus padding); otherwise its size stays.
    public var hugsContents: Bool

    public init(direction: Direction = .horizontal, spacing: Double = 8, padding: Insets = Insets(), alignment: Alignment = .start, hugsContents: Bool = true) {
        self.direction = direction
        self.spacing = spacing
        self.padding = padding
        self.alignment = alignment
        self.hugsContents = hugsContents
    }
}

public struct Insets: Codable, Equatable, Hashable, Sendable {
    public var top: Double
    public var right: Double
    public var bottom: Double
    public var left: Double

    public init(top: Double = 0, right: Double = 0, bottom: Double = 0, left: Double = 0) {
        self.top = top
        self.right = right
        self.bottom = bottom
        self.left = left
    }

    public init(all value: Double) {
        self.init(top: value, right: value, bottom: value, left: value)
    }

    /// CSS-style shorthand: `8`, `8 16` (vertical horizontal), `8 16 4`, `8 16 4 2` (top right bottom left).
    public init?(parsing text: String) {
        let values = text.split(whereSeparator: { $0 == " " || $0 == "," }).compactMap { Double($0) }
        switch values.count {
        case 1: self.init(all: values[0])
        case 2: self.init(top: values[0], right: values[1], bottom: values[0], left: values[1])
        case 3: self.init(top: values[0], right: values[1], bottom: values[2], left: values[1])
        case 4: self.init(top: values[0], right: values[1], bottom: values[2], left: values[3])
        default: return nil
        }
    }

    /// The shortest shorthand that gives these insets.
    public var shorthand: String {
        let n = { (value: Double) in value == value.rounded() ? String(Int(value)) : String(value) }
        if top == right, right == bottom, bottom == left { return n(top) }
        if top == bottom, left == right { return "\(n(top)) \(n(right))" }
        if left == right { return "\(n(top)) \(n(right)) \(n(bottom))" }
        return "\(n(top)) \(n(right)) \(n(bottom)) \(n(left))"
    }
}
