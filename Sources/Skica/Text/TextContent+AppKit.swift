import AppKit
import SkicaCore

/// Converts text between the document model and the AppKit text system used while editing.
extension TextContent {
    func appKitString() -> NSAttributedString {
        let result = NSMutableAttributedString()
        for run in runs where !run.text.isEmpty {
            result.append(NSAttributedString(string: run.text, attributes: run.style.appKitAttributes(alignment: alignment)))
        }
        return result
    }

    /// Reads runs back from edited text; attributes the text system does not know keep the
    /// values of `base`.
    static func from(_ string: NSAttributedString, base: TextContent) -> TextContent {
        var runs: [TextRun] = []
        let fallback = base.leadingStyle
        string.enumerateAttributes(in: NSRange(location: 0, length: string.length)) { attributes, range, _ in
            let text = (string.string as NSString).substring(with: range)
            runs.append(TextRun(text: text, style: TextStyle(appKitAttributes: attributes, fallback: fallback)))
        }
        var content = base
        content.runs = runs
        return content.normalized()
    }
}

extension TextStyle {
    func appKitAttributes(alignment: TextContent.Alignment) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment.nsAlignment
        if let lineHeight {
            paragraph.minimumLineHeight = lineHeight
            paragraph.maximumLineHeight = lineHeight
        }
        var attributes: [NSAttributedString.Key: Any] = [
            .font: nsFont,
            .foregroundColor: NSColor(cgColor: color.cgColor) ?? .black,
            .kern: letterSpacing,
            .paragraphStyle: paragraph,
        ]
        if underline { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        return attributes
    }

    init(appKitAttributes attributes: [NSAttributedString.Key: Any], fallback: TextStyle) {
        self = fallback
        if let font = attributes[.font] as? NSFont {
            fontName = font.fontName
            fontSize = font.pointSize
        }
        if let color = (attributes[.foregroundColor] as? NSColor).flatMap({ SkicaCore.Color(cgColor: $0.cgColor) }) {
            self.color = color
        }
        letterSpacing = (attributes[.kern] as? NSNumber)?.doubleValue ?? 0
        if let paragraph = attributes[.paragraphStyle] as? NSParagraphStyle {
            lineHeight = paragraph.maximumLineHeight > 0 ? paragraph.maximumLineHeight : nil
        }
        underline = ((attributes[.underlineStyle] as? NSNumber)?.intValue ?? 0) != 0
    }

    var nsFont: NSFont {
        NSFont(name: fontName, size: fontSize) ?? .systemFont(ofSize: fontSize)
    }

    var familyName: String {
        nsFont.familyName ?? fontName
    }

    /// The face's style within its family, e.g. "Bold Italic".
    var faceName: String {
        let members = NSFontManager.shared.availableMembers(ofFontFamily: familyName) ?? []
        return members.first { ($0.first as? String) == fontName }.flatMap { $0[safe: 1] as? String } ?? "Regular"
    }

    /// The face of `family` closest in weight and slant to this style's face.
    func closestFace(in family: String) -> String? {
        let manager = NSFontManager.shared
        guard let members = manager.availableMembers(ofFontFamily: family), !members.isEmpty else { return nil }
        let weight = manager.weight(of: nsFont)
        let italic = manager.traits(of: nsFont).contains(.italicFontMask)
        let best = members.min { lhs, rhs in
            score(lhs, weight: weight, italic: italic) < score(rhs, weight: weight, italic: italic)
        }
        return best?.first as? String
    }

    private func score(_ member: [Any], weight: Int, italic: Bool) -> Int {
        let memberWeight = (member[safe: 2] as? NSNumber)?.intValue ?? 5
        let traits = NSFontTraitMask(rawValue: (member[safe: 3] as? NSNumber)?.uintValue ?? 0)
        return abs(memberWeight - weight) + (traits.contains(.italicFontMask) == italic ? 0 : 10)
    }

    /// The same family with the trait added or removed, e.g. for ⌘B.
    func converting(_ trait: NSFontTraitMask, on: Bool) -> TextStyle {
        let manager = NSFontManager.shared
        let converted = on ? manager.convert(nsFont, toHaveTrait: trait) : manager.convert(nsFont, toNotHaveTrait: trait)
        var copy = self
        copy.fontName = converted.fontName
        return copy
    }

    func has(_ trait: NSFontTraitMask) -> Bool {
        NSFontManager.shared.traits(of: nsFont).contains(trait)
    }
}

extension TextContent.Alignment {
    var nsAlignment: NSTextAlignment {
        switch self {
        case .left: .left
        case .center: .center
        case .right: .right
        case .justified: .justified
        }
    }
}
