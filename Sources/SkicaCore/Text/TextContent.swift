import Foundation

/// The text of a text layer: runs of styled text, alignment, and how the frame follows the text.
public struct TextContent: Codable, Equatable, Sendable {
    public enum Alignment: String, Codable, CaseIterable, Sendable {
        case left, center, right, justified
    }

    public enum Sizing: String, Codable, CaseIterable, Sendable {
        /// One line per paragraph; the frame grows sideways with the text.
        case autoWidth
        /// Fixed width with wrapping; the height follows the text.
        case autoHeight
        /// Both sizes are set by hand; text may overflow.
        case fixed

        public var title: String {
            switch self {
            case .autoWidth: "Auto Width"
            case .autoHeight: "Auto Height"
            case .fixed: "Fixed Size"
            }
        }
    }

    public var runs: [TextRun]
    public var alignment: Alignment
    public var sizing: Sizing

    public init(runs: [TextRun], alignment: Alignment = .left, sizing: Sizing = .autoWidth) {
        self.runs = runs
        self.alignment = alignment
        self.sizing = sizing
    }

    public init(_ text: String, style: TextStyle = TextStyle(), alignment: Alignment = .left, sizing: Sizing = .autoWidth) {
        self.init(runs: [TextRun(text: text, style: style)], alignment: alignment, sizing: sizing)
    }

    public var string: String { runs.map(\.text).joined() }

    /// The style used for new text: that of the first run, or the default.
    public var leadingStyle: TextStyle { runs.first?.style ?? TextStyle() }

    /// Applies a change to every run's style.
    public mutating func updateStyles(_ body: (inout TextStyle) -> Void) {
        for index in runs.indices { body(&runs[index].style) }
        if runs.isEmpty {
            var style = TextStyle()
            body(&style)
            runs = [TextRun(text: "", style: style)]
        }
    }

    /// Joins neighboring runs with the same style and drops empty ones (keeping one run).
    public func normalized() -> TextContent {
        var merged: [TextRun] = []
        for run in runs where !run.text.isEmpty {
            if let last = merged.last, last.style == run.style {
                merged[merged.count - 1].text += run.text
            } else {
                merged.append(run)
            }
        }
        if merged.isEmpty { merged = [TextRun(text: "", style: leadingStyle)] }
        var copy = self
        copy.runs = merged
        return copy
    }
}

public struct TextRun: Codable, Equatable, Sendable {
    public var text: String
    public var style: TextStyle

    public init(text: String, style: TextStyle) {
        self.text = text
        self.style = style
    }
}

public struct TextStyle: Codable, Equatable, Hashable, Sendable {
    public static let defaultFont = "HelveticaNeue"

    /// The PostScript name of the exact face, e.g. `HelveticaNeue-Bold`.
    public var fontName: String
    public var fontSize: Double
    public var color: Color
    /// Extra space between letters, in points.
    public var letterSpacing: Double
    /// The distance between baselines in points; nil uses the font's own.
    public var lineHeight: Double?
    public var underline: Bool

    public init(fontName: String = TextStyle.defaultFont, fontSize: Double = 16, color: Color = Color(red: 0x1C, green: 0x1C, blue: 0x1E),
                letterSpacing: Double = 0, lineHeight: Double? = nil, underline: Bool = false) {
        self.fontName = fontName
        self.fontSize = fontSize
        self.color = color
        self.letterSpacing = letterSpacing
        self.lineHeight = lineHeight
        self.underline = underline
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fontName = try container.decode(CodingKeys.fontName, default: TextStyle.defaultFont)
        fontSize = try container.decode(CodingKeys.fontSize, default: 16)
        color = try container.decode(CodingKeys.color, default: .black)
        letterSpacing = try container.decode(CodingKeys.letterSpacing, default: 0)
        lineHeight = try container.decodeIfPresent(Double.self, forKey: .lineHeight)
        underline = try container.decode(CodingKeys.underline, default: false)
    }
}
