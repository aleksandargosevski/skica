import Foundation

/// One file to export a layer as: a size, a file-name suffix and a format, e.g. `2x`, `@2x`, PNG.
public struct ExportPreset: Codable, Equatable, Hashable, Sendable {
    public enum Format: String, Codable, CaseIterable, Sendable {
        case png, jpg, webp, heic, avif, pdf, svg

        public var title: String { rawValue.uppercased() }

        /// Vector formats are written at their natural size; the size is ignored.
        public var isVector: Bool { self == .pdf || self == .svg }
    }

    /// How big the file is: a scale (`2x`), or a fixed width (`512w`) or height (`300h`).
    public enum Size: Equatable, Hashable, Sendable, CustomStringConvertible {
        case scale(Double)
        case width(Double)
        case height(Double)

        /// Parses `2x`, `2`, `0.5x`, `512w`, `300h`.
        public init?(parsing text: String) {
            let trimmed = text.trimmingCharacters(in: .whitespaces).lowercased()
            guard let last = trimmed.last else { return nil }
            let number = "xwh".contains(last) ? String(trimmed.dropLast()) : trimmed
            guard let value = Double(number), value > 0 else { return nil }
            switch last {
            case "w": self = .width(value)
            case "h": self = .height(value)
            default: self = .scale(value)
            }
        }

        public var description: String {
            switch self {
            case .scale(let value): Self.format(value) + "x"
            case .width(let value): Self.format(value) + "w"
            case .height(let value): Self.format(value) + "h"
            }
        }

        /// The scale that gives this size for content of `size` points.
        public func scale(for width: Double, height: Double) -> Double {
            switch self {
            case .scale(let value): value
            case .width(let value): width > 0 ? value / width : 1
            case .height(let value): height > 0 ? value / height : 1
            }
        }

        private static func format(_ value: Double) -> String {
            value == value.rounded() ? String(Int(value)) : String(value)
        }
    }

    public var size: Size
    public var suffix: String
    public var format: Format

    public init(size: Size = .scale(1), suffix: String = "", format: Format = .png) {
        self.size = size
        self.suffix = suffix
        self.format = format
    }

    /// The usual suffix for a size: `@2x` for 2x, nothing for 1x.
    public static func defaultSuffix(for size: Size) -> String {
        if case .scale(let value) = size, value != 1 { return "@\(size)" }
        return ""
    }

    /// The next preset to offer after `existing`: 1x, then 2x, then 3x…
    public static func next(after existing: [ExportPreset]) -> ExportPreset {
        let scales = existing.compactMap { preset -> Double? in
            if case .scale(let value) = preset.size { return value }
            return nil
        }
        let scale = (scales.max() ?? 0) + 1
        let size = Size.scale(scale)
        return ExportPreset(size: size, suffix: defaultSuffix(for: size), format: existing.last?.format ?? .png)
    }

    enum CodingKeys: String, CodingKey {
        case size, suffix, format
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let text = try container.decode(String.self, forKey: .size)
        guard let size = Size(parsing: text) else {
            throw DecodingError.dataCorruptedError(forKey: .size, in: container, debugDescription: "Invalid export size \"\(text)\"")
        }
        self.size = size
        suffix = try container.decode(CodingKeys.suffix, default: "")
        format = try container.decode(CodingKeys.format, default: .png)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(size.description, forKey: .size)
        try container.encode(suffix, forKey: .suffix)
        try container.encode(format, forKey: .format)
    }
}
