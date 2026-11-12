import Foundation

public typealias SharedStyleID = Identifier<SharedStyle>
public typealias SwatchID = Identifier<Swatch>
public typealias SymbolID = Identifier<SymbolTag>

/// Phantom type for symbol IDs (symbols are master layers, not a struct of their own).
public enum SymbolTag {}

/// Things a document defines once and reuses: shared styles and the color palette.
public struct DocumentAssets: Codable, Equatable, Sendable {
    public var sharedStyles: [SharedStyle]
    public var swatches: [Swatch]

    public init(sharedStyles: [SharedStyle] = [], swatches: [Swatch] = []) {
        self.sharedStyles = sharedStyles
        self.swatches = swatches
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sharedStyles = try container.decode(CodingKeys.sharedStyles, default: [])
        swatches = try container.decode(CodingKeys.swatches, default: [])
    }

    public func sharedStyle(_ id: SharedStyleID) -> SharedStyle? {
        sharedStyles.first { $0.id == id }
    }

    /// A swatch by name, ignoring case and spaces (`$brand primary` finds "Brand Primary").
    public func swatch(named name: String) -> Swatch? {
        let wanted = name.lowercased().filter { !$0.isWhitespace }
        return swatches.first { $0.name.lowercased().filter { !$0.isWhitespace } == wanted }
    }
}

/// A named style that layers link to; changing it changes them all.
public struct SharedStyle: Codable, Equatable, Sendable, Identifiable {
    public enum Content: Codable, Equatable, Sendable {
        /// Fills, borders, shadows, blur and blend mode of shapes.
        case layer(Style)
        /// Font, size, color and spacing of text, and its alignment.
        case text(TextStyle, alignment: TextContent.Alignment)
    }

    public var id: SharedStyleID
    public var name: String
    public var content: Content

    public init(id: SharedStyleID = .make(), name: String, content: Content) {
        self.id = id
        self.name = name
        self.content = content
    }

    public var isTextStyle: Bool {
        if case .text = content { return true }
        return false
    }
}

/// A named color of the document's palette.
public struct Swatch: Codable, Equatable, Sendable, Identifiable {
    public var id: SwatchID
    public var name: String
    public var color: Color

    public init(id: SwatchID = .make(), name: String, color: Color) {
        self.id = id
        self.name = name
        self.color = color
    }
}
