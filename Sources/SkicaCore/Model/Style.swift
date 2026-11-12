import Foundation

/// How a layer is painted: fills bottom to top, borders, shadows, blur and blend mode.
/// Fields added after format 1 decode with defaults, so older files keep opening.
public struct Style: Codable, Equatable, Sendable {
    public var fills: [Fill]
    public var borders: [Border]
    public var shadows: [Shadow]
    public var innerShadows: [Shadow]
    public var blur: Blur?
    public var blendMode: BlendMode

    public init(
        fills: [Fill] = [], borders: [Border] = [], shadows: [Shadow] = [], innerShadows: [Shadow] = [],
        blur: Blur? = nil, blendMode: BlendMode = .normal
    ) {
        self.fills = fills
        self.borders = borders
        self.shadows = shadows
        self.innerShadows = innerShadows
        self.blur = blur
        self.blendMode = blendMode
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fills = try container.decode(CodingKeys.fills, default: [])
        borders = try container.decode(CodingKeys.borders, default: [])
        shadows = try container.decode(CodingKeys.shadows, default: [])
        innerShadows = try container.decode(CodingKeys.innerShadows, default: [])
        blur = try container.decodeIfPresent(Blur.self, forKey: .blur)
        blendMode = try container.decode(CodingKeys.blendMode, default: .normal)
    }
}

public struct Fill: Codable, Equatable, Sendable {
    public var isEnabled: Bool
    /// The solid color; ignored while `gradient` is set.
    public var color: Color
    public var gradient: Gradient?

    public init(_ color: Color, gradient: Gradient? = nil, isEnabled: Bool = true) {
        self.color = color
        self.gradient = gradient
        self.isEnabled = isEnabled
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try container.decode(CodingKeys.isEnabled, default: true)
        color = try container.decode(Color.self, forKey: .color)
        gradient = try container.decodeIfPresent(Gradient.self, forKey: .gradient)
    }
}

public struct Gradient: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case linear, radial
    }

    public var kind: Kind
    /// Start and end in the layer's unit square; for radial gradients, the center and a point on the edge.
    public var from: UnitPoint
    public var to: UnitPoint
    public var stops: [GradientStop]

    public init(kind: Kind = .linear, from: UnitPoint = UnitPoint(x: 0.5, y: 0), to: UnitPoint = UnitPoint(x: 0.5, y: 1), stops: [GradientStop]) {
        self.kind = kind
        self.from = from
        self.to = to
        self.stops = stops
    }

    /// A gradient from `color` to the same color fully transparent, top to bottom.
    public static func fading(_ color: Color, kind: Kind = .linear) -> Gradient {
        var clear = color
        clear.alpha = 0
        let center = UnitPoint(x: 0.5, y: 0.5)
        return kind == .linear
            ? Gradient(kind: .linear, stops: [GradientStop(position: 0, color: color), GradientStop(position: 1, color: clear)])
            : Gradient(kind: .radial, from: center, to: UnitPoint(x: 1, y: 0.5), stops: [GradientStop(position: 0, color: color), GradientStop(position: 1, color: clear)])
    }

    /// Direction of a linear gradient in degrees: 0 points right, 90 down.
    public var angle: Double {
        get { atan2(to.y - from.y, to.x - from.x) * 180 / .pi }
        set {
            let radians = newValue * .pi / 180
            let dx = cos(radians) / 2
            let dy = sin(radians) / 2
            from = UnitPoint(x: 0.5 - dx, y: 0.5 - dy)
            to = UnitPoint(x: 0.5 + dx, y: 0.5 + dy)
        }
    }
}

public struct GradientStop: Codable, Equatable, Sendable {
    /// 0…1 along the gradient.
    public var position: Double
    public var color: Color

    public init(position: Double, color: Color) {
        self.position = position
        self.color = color
    }
}

public struct Border: Codable, Equatable, Sendable {
    public enum Position: String, Codable, CaseIterable, Sendable {
        case center, inside, outside
    }

    public enum Cap: String, Codable, CaseIterable, Sendable {
        case butt, round, square
    }

    public enum Join: String, Codable, CaseIterable, Sendable {
        case miter, round, bevel
    }

    public var isEnabled: Bool
    public var color: Color
    public var width: Double
    public var position: Position
    /// Dash and gap lengths, repeating; empty for a solid line.
    public var dashes: [Double]
    public var cap: Cap
    public var join: Join

    public init(_ color: Color, width: Double = 1, position: Position = .center, dashes: [Double] = [],
                cap: Cap = .butt, join: Join = .miter, isEnabled: Bool = true) {
        self.color = color
        self.width = width
        self.position = position
        self.dashes = dashes
        self.cap = cap
        self.join = join
        self.isEnabled = isEnabled
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try container.decode(CodingKeys.isEnabled, default: true)
        color = try container.decode(Color.self, forKey: .color)
        width = try container.decode(CodingKeys.width, default: 1)
        position = try container.decode(CodingKeys.position, default: .center)
        dashes = try container.decode(CodingKeys.dashes, default: [])
        cap = try container.decode(CodingKeys.cap, default: .butt)
        join = try container.decode(CodingKeys.join, default: .miter)
    }
}

/// A drop shadow or inner shadow. Offsets and blur are in layer units and scale with zoom.
public struct Shadow: Codable, Equatable, Sendable {
    public var isEnabled: Bool
    public var color: Color
    public var x: Double
    public var y: Double
    public var blur: Double
    public var spread: Double

    public init(color: Color = Color(red: 0, green: 0, blue: 0, alpha: 64), x: Double = 0, y: Double = 4, blur: Double = 8, spread: Double = 0, isEnabled: Bool = true) {
        self.color = color
        self.x = x
        self.y = y
        self.blur = blur
        self.spread = spread
        self.isEnabled = isEnabled
    }
}

/// A Gaussian blur of the whole layer.
public struct Blur: Codable, Equatable, Sendable {
    public var isEnabled: Bool
    public var radius: Double

    public init(radius: Double = 4, isEnabled: Bool = true) {
        self.radius = radius
        self.isEnabled = isEnabled
    }
}

public enum BlendMode: String, Codable, CaseIterable, Sendable {
    case normal, darken, multiply, colorBurn, lighten, screen, colorDodge, overlay, softLight, hardLight,
         difference, exclusion, hue, saturation, color, luminosity

    public var title: String {
        switch self {
        case .normal: "Normal"
        case .darken: "Darken"
        case .multiply: "Multiply"
        case .colorBurn: "Color Burn"
        case .lighten: "Lighten"
        case .screen: "Screen"
        case .colorDodge: "Color Dodge"
        case .overlay: "Overlay"
        case .softLight: "Soft Light"
        case .hardLight: "Hard Light"
        case .difference: "Difference"
        case .exclusion: "Exclusion"
        case .hue: "Hue"
        case .saturation: "Saturation"
        case .color: "Color"
        case .luminosity: "Luminosity"
        }
    }
}

/// An sRGB color with 8 bits per channel, stored in JSON as `#RRGGBB` or `#RRGGBBAA`.
public struct Color: Codable, Equatable, Hashable, Sendable, CustomStringConvertible {
    public var red: UInt8
    public var green: UInt8
    public var blue: UInt8
    public var alpha: UInt8

    public init(red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8 = 255) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    public static let black = Color(red: 0, green: 0, blue: 0)
    public static let white = Color(red: 255, green: 255, blue: 255)

    /// Accepts `#rgb`, `#rrggbb` and `#rrggbbaa`, with or without `#`.
    public init?(hex: String) {
        var digits = hex.trimmingCharacters(in: .whitespaces)
        if digits.hasPrefix("#") { digits.removeFirst() }
        if digits.count == 3 { digits = digits.map { "\($0)\($0)" }.joined() }
        guard digits.count == 6 || digits.count == 8, let value = UInt32(digits, radix: 16) else { return nil }
        let full = digits.count == 6 ? value << 8 | 0xFF : value
        self.init(
            red: UInt8(full >> 24 & 0xFF),
            green: UInt8(full >> 16 & 0xFF),
            blue: UInt8(full >> 8 & 0xFF),
            alpha: UInt8(full & 0xFF)
        )
    }

    public var hex: String {
        let rgb = String(format: "#%02X%02X%02X", red, green, blue)
        return alpha == 255 ? rgb : rgb + String(format: "%02X", alpha)
    }

    public var description: String { hex }

    public var components: (red: Double, green: Double, blue: Double, alpha: Double) {
        (Double(red) / 255, Double(green) / 255, Double(blue) / 255, Double(alpha) / 255)
    }

    public init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let color = Color(hex: text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid color \"\(text)\""))
        }
        self = color
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(hex)
    }
}

extension KeyedDecodingContainer {
    /// Decodes an optional key, falling back to `default` when it is missing.
    func decode<T: Decodable>(_ key: Key, default defaultValue: T) throws -> T {
        try decodeIfPresent(T.self, forKey: key) ?? defaultValue
    }
}
