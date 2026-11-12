import Foundation

/// A stable, typed identifier stored as a plain string in JSON.
public struct Identifier<Tag>: Hashable, Codable, Sendable, CodingKeyRepresentable, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public static func make() -> Self {
        Self(UUID().uuidString)
    }

    public var description: String { rawValue }

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var codingKey: CodingKey { StringCodingKey(rawValue) }

    public init?<Key: CodingKey>(codingKey: Key) {
        self.init(codingKey.stringValue)
    }
}

public typealias LayerID = Identifier<Layer>
public typealias PageID = Identifier<Page>

struct StringCodingKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }

    init(_ stringValue: String) { self.stringValue = stringValue }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}
