import CoreText
import Foundation

/// Finds installed font faces by family name and CSS-style weight (100–900) with Core Text.
public enum FontFaces {
    /// The PostScript name of the face of `family` closest to `weight` and `italic`, or nil
    /// when no such family is installed.
    public static func face(family: String, weight: Int?, italic: Bool = false) -> String? {
        guard let familyName = installedFamily(matching: family) else { return nil }
        var traits: [CFString: Any] = [:]
        if let weight { traits[kCTFontWeightTrait] = coreTextWeight(weight) }
        if italic { traits[kCTFontSymbolicTrait] = CTFontSymbolicTraits.traitItalic.rawValue }
        let attributes: [CFString: Any] = [kCTFontFamilyNameAttribute: familyName, kCTFontTraitsAttribute: traits]
        let descriptor = CTFontDescriptorCreateWithAttributes(attributes as CFDictionary)
        let font = CTFontCreateWithFontDescriptor(descriptor, 12, nil)
        guard (CTFontCopyFamilyName(font) as String).lowercased() == familyName.lowercased() else { return nil }
        return CTFontCopyPostScriptName(font) as String
    }

    /// The installed family name matching `name` regardless of case and spaces.
    public static func installedFamily(matching name: String) -> String? {
        let wanted = normalize(name)
        let families = CTFontManagerCopyAvailableFontFamilyNames() as? [String] ?? []
        return families.first { normalize($0) == wanted }
    }

    private static func normalize(_ name: String) -> String {
        name.lowercased().filter { !$0.isWhitespace && $0 != "-" }
    }

    /// CSS weights mapped onto Core Text's -1…1 weight scale.
    private static func coreTextWeight(_ weight: Int) -> Double {
        let table: [(Int, Double)] = [(100, -0.8), (200, -0.6), (300, -0.4), (400, 0), (500, 0.23), (600, 0.3), (700, 0.4), (800, 0.56), (900, 0.62)]
        return table.min { abs($0.0 - weight) < abs($1.0 - weight) }?.1 ?? 0
    }
}

/// What SVG and CSS need to name a font face: family, weight (100–900) and slant.
public struct TextFontInfo: Equatable, Sendable {
    public var family: String
    public var weight: Int
    public var isItalic: Bool
    public var postScriptName: String

    public init(_ font: CTFont) {
        family = CTFontCopyFamilyName(font) as String
        postScriptName = CTFontCopyPostScriptName(font) as String
        let traits = CTFontCopyTraits(font) as NSDictionary
        let coreTextWeight = (traits[kCTFontWeightTrait] as? NSNumber)?.doubleValue ?? 0
        weight = Self.cssWeight(coreTextWeight)
        let symbolic = (traits[kCTFontSymbolicTrait] as? NSNumber)?.uint32Value ?? 0
        isItalic = CTFontSymbolicTraits(rawValue: symbolic).contains(.traitItalic)
    }

    /// Core Text's -1…1 weight scale mapped onto CSS weights, rounded to hundreds.
    static func cssWeight(_ value: Double) -> Int {
        let table: [(Double, Int)] = [(-0.8, 100), (-0.6, 200), (-0.4, 300), (0, 400), (0.23, 500), (0.3, 600), (0.4, 700), (0.56, 800), (0.62, 900)]
        return table.min { abs($0.0 - value) < abs($1.0 - value) }?.1 ?? 400
    }
}
