import Foundation

/// Size and position typed after creating a shape: `200x120`, `200x120 @ 40,80`, `@ 40,80`,
/// `150` (a square), `x60` (height only). Each value can be arithmetic, and `+20` / `*2`
/// change the current value.
public struct GeometryInput: Equatable, Sendable {
    public var width: Double?
    public var height: Double?
    public var x: Double?
    public var y: Double?

    public init(width: Double? = nil, height: Double? = nil, x: Double? = nil, y: Double? = nil) {
        self.width = width
        self.height = height
        self.x = x
        self.y = y
    }

    public func applied(to frame: Rect) -> Rect {
        Rect(x: x ?? frame.x, y: y ?? frame.y, width: max(width ?? frame.width, 0), height: max(height ?? frame.height, 0))
    }
}

public enum GeometryPrompt {
    public static func parse(_ text: String, current: Rect) throws -> GeometryInput {
        let parts = text.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw InputError.invalid("Type a size like 200x120, a position like @ 40,80, or both.")
        }
        var input = GeometryInput()
        if let size = parts.first, !size.isEmpty {
            do {
                try parseSize(size, current: current, into: &input)
            } catch {
                // A name like "iphone" or "a4" sizes the layer like that preset.
                guard size.first?.isLetter == true, let preset = ArtboardPreset.matching(size) else { throw error }
                input.width = preset.width
                input.height = preset.height
            }
        }
        if parts.count == 2 {
            try parsePosition(parts[1], current: current, into: &input)
        }
        return input
    }

    private static func parseSize(_ text: String, current: Rect, into input: inout GeometryInput) throws {
        let parts = text.split(omittingEmptySubsequences: false, whereSeparator: { "xX×".contains($0) }).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        if parts.count == 1 {
            let value = try value(text, current: current.width)
            input.width = value
            input.height = value
            return
        }
        guard parts.count == 2 else { throw InputError.invalid("Write a size as width x height.") }
        if !parts[0].isEmpty { input.width = try value(parts[0], current: current.width) }
        if parts.count > 1, !parts[1].isEmpty { input.height = try value(parts[1], current: current.height) }
    }

    private static func parsePosition(_ text: String, current: Rect, into input: inout GeometryInput) throws {
        let parts: [String]
        if text.contains(",") {
            parts = text.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        } else {
            parts = text.split(separator: " ").map(String.init)
        }
        guard !parts.isEmpty, parts.count <= 2 else { throw InputError.invalid("Write a position as @ x,y.") }
        if !parts[0].isEmpty { input.x = try value(parts[0], current: current.x) }
        if parts.count > 1, !parts[1].isEmpty { input.y = try value(parts[1], current: current.y) }
    }

    private static func value(_ text: String, current: Double) throws -> Double {
        try NumericExpression.evaluate(text, current: current)
    }
}
