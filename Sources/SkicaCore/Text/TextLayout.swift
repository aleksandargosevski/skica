import CoreGraphics
import CoreText
import Foundation

/// Lays out and draws text with Core Text. Measuring lives here (not in the renderer) because
/// edits need it to size text frames.
public enum TextLayout {
    /// Room for any width when the text sets its own width.
    private static let unlimited: CGFloat = 100_000

    /// The size the text needs; `width` wraps lines, nil keeps one line per paragraph.
    public static func size(of content: TextContent, width: CGFloat?) -> CGSize {
        let framesetter = CTFramesetterCreateWithAttributedString(attributedString(content))
        let constraint = CGSize(width: width ?? unlimited, height: unlimited)
        let fitted = CTFramesetterSuggestFrameSizeWithConstraints(framesetter, CFRange(location: 0, length: 0), nil, constraint, nil)
        let lineHeight = emptyLineHeight(content.leadingStyle)
        return CGSize(width: ceil(width ?? fitted.width), height: ceil(max(fitted.height, lineHeight)))
    }

    /// Draws the text into `frame` in a context whose y axis points down.
    public static func draw(_ content: TextContent, in frame: CGRect, context: CGContext) {
        guard !content.string.isEmpty else { return }
        let framesetter = CTFramesetterCreateWithAttributedString(attributedString(content))
        // Auto-width text never wraps, even if the frame is a hair narrower than the text.
        let width = content.sizing == .autoWidth ? max(frame.width, size(of: content, width: nil).width) + 0.5 : frame.width
        let path = CGPath(rect: CGRect(x: 0, y: 0, width: width, height: max(frame.height, unlimited)), transform: nil)
        let ctFrame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)

        context.saveGState()
        context.textMatrix = .identity
        // Core Text draws upward from the bottom of its path; flip so the first line sits at the top.
        context.translateBy(x: frame.minX, y: frame.minY + unlimited)
        context.scaleBy(x: 1, y: -1)
        CTFrameDraw(ctFrame, context)
        context.restoreGState()
    }

    /// A line of laid-out text: its baseline (in the coordinates of `frame`, y down) and its
    /// pieces in one style each, with where each starts.
    public struct Line: Sendable {
        public var baseline: CGPoint
        public var pieces: [Piece]
    }

    public struct Piece: Sendable {
        public var x: CGFloat
        public var text: String
        public var font: TextFontInfo
        public var style: TextStyle
    }

    /// The text broken into lines exactly as `draw` lays it out, for writing SVG.
    public static func lines(of content: TextContent, in frame: CGRect) -> [Line] {
        guard !content.string.isEmpty else { return [] }
        let string = attributedString(content)
        let framesetter = CTFramesetterCreateWithAttributedString(string)
        let width = content.sizing == .autoWidth ? max(frame.width, size(of: content, width: nil).width) + 0.5 : frame.width
        let path = CGPath(rect: CGRect(x: 0, y: 0, width: width, height: unlimited), transform: nil)
        let ctFrame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)
        let ctLines = CTFrameGetLines(ctFrame) as? [CTLine] ?? []
        var origins = [CGPoint](repeating: .zero, count: ctLines.count)
        CTFrameGetLineOrigins(ctFrame, CFRange(location: 0, length: 0), &origins)

        let text = string.string as NSString
        let styles = styleRanges(content)
        return zip(ctLines, origins).map { line, origin in
            let runs = CTLineGetGlyphRuns(line) as? [CTRun] ?? []
            let pieces = runs.compactMap { run -> Piece? in
                let range = CTRunGetStringRange(run)
                let piece = text.substring(with: NSRange(location: range.location, length: range.length))
                    .trimmingCharacters(in: .newlines)
                guard !piece.isEmpty else { return nil }
                var position = CGPoint.zero
                CTRunGetPositions(run, CFRange(location: 0, length: 1), &position)
                let attributes = CTRunGetAttributes(run) as NSDictionary
                let font = attributes[kCTFontAttributeName] as! CTFont
                let style = styles.last { $0.location <= range.location }?.style ?? content.leadingStyle
                return Piece(x: frame.minX + origin.x + position.x, text: piece, font: TextFontInfo(font), style: style)
            }
            return Line(baseline: CGPoint(x: frame.minX + origin.x, y: frame.minY + unlimited - origin.y), pieces: pieces)
        }
    }

    /// The letters as paths in `frame`'s coordinates (y down), one path per text color.
    public static func outlines(of content: TextContent, in frame: CGRect) -> [(color: Color, path: CGPath)] {
        guard !content.string.isEmpty else { return [] }
        let string = attributedString(content)
        let framesetter = CTFramesetterCreateWithAttributedString(string)
        let width = content.sizing == .autoWidth ? max(frame.width, size(of: content, width: nil).width) + 0.5 : frame.width
        let path = CGPath(rect: CGRect(x: 0, y: 0, width: width, height: unlimited), transform: nil)
        let ctFrame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)
        let lines = CTFrameGetLines(ctFrame) as? [CTLine] ?? []
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(ctFrame, CFRange(location: 0, length: 0), &origins)
        let styles = styleRanges(content)

        var byColor: [(color: Color, path: CGMutablePath)] = []
        for (line, origin) in zip(lines, origins) {
            for run in CTLineGetGlyphRuns(line) as? [CTRun] ?? [] {
                let count = CTRunGetGlyphCount(run)
                guard count > 0 else { continue }
                let attributes = CTRunGetAttributes(run) as NSDictionary
                let font = attributes[kCTFontAttributeName] as! CTFont
                let range = CTRunGetStringRange(run)
                let color = styles.last { $0.location <= range.location }?.style.color ?? content.leadingStyle.color
                var glyphs = [CGGlyph](repeating: 0, count: count)
                var positions = [CGPoint](repeating: .zero, count: count)
                CTRunGetGlyphs(run, CFRange(location: 0, length: count), &glyphs)
                CTRunGetPositions(run, CFRange(location: 0, length: count), &positions)
                let target: CGMutablePath
                if let existing = byColor.first(where: { $0.color == color }) {
                    target = existing.path
                } else {
                    target = CGMutablePath()
                    byColor.append((color, target))
                }
                for (glyph, position) in zip(glyphs, positions) {
                    guard let letter = CTFontCreatePathForGlyph(font, glyph, nil) else { continue }
                    // Glyphs are drawn upward from the baseline; flip them into the y-down frame.
                    let baseline = CGPoint(x: frame.minX + origin.x + position.x, y: frame.minY + unlimited - origin.y)
                    let transform = CGAffineTransform(translationX: baseline.x, y: baseline.y).scaledBy(x: 1, y: -1)
                    target.addPath(letter, transform: transform)
                }
            }
        }
        return byColor.map { ($0.color, $0.path as CGPath) }
    }

    /// Where each run starts in the joined string, in UTF-16 units.
    private static func styleRanges(_ content: TextContent) -> [(location: Int, style: TextStyle)] {
        var location = 0
        return content.runs.filter { !$0.text.isEmpty }.map { run in
            defer { location += run.text.utf16.count }
            return (location, run.style)
        }
    }

    /// The text as an attributed string with Core Text attributes.
    public static func attributedString(_ content: TextContent) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for run in content.runs where !run.text.isEmpty {
            result.append(NSAttributedString(string: run.text, attributes: attributes(for: run.style, alignment: content.alignment)))
        }
        return result
    }

    public static func font(for style: TextStyle) -> CTFont {
        CTFontCreateWithName(style.fontName as CFString, style.fontSize, nil)
    }

    static func attributes(for style: TextStyle, alignment: TextContent.Alignment) -> [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font(for: style),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): cgColor(style.color),
            NSAttributedString.Key(kCTKernAttributeName as String): style.letterSpacing,
            NSAttributedString.Key(kCTParagraphStyleAttributeName as String): paragraphStyle(alignment: alignment, lineHeight: style.lineHeight),
        ]
        if style.underline {
            attributes[NSAttributedString.Key(kCTUnderlineStyleAttributeName as String)] = CTUnderlineStyle.single.rawValue
        }
        return attributes
    }

    private static func paragraphStyle(alignment: TextContent.Alignment, lineHeight: Double?) -> CTParagraphStyle {
        var textAlignment: CTTextAlignment = switch alignment {
        case .left: .left
        case .center: .center
        case .right: .right
        case .justified: .justified
        }
        var height = CGFloat(lineHeight ?? 0)
        return withUnsafeBytes(of: &textAlignment) { alignmentBytes in
            withUnsafeBytes(of: &height) { heightBytes in
                var settings = [CTParagraphStyleSetting(spec: .alignment, valueSize: MemoryLayout<CTTextAlignment>.size, value: alignmentBytes.baseAddress!)]
                if lineHeight != nil {
                    settings.append(CTParagraphStyleSetting(spec: .minimumLineHeight, valueSize: MemoryLayout<CGFloat>.size, value: heightBytes.baseAddress!))
                    settings.append(CTParagraphStyleSetting(spec: .maximumLineHeight, valueSize: MemoryLayout<CGFloat>.size, value: heightBytes.baseAddress!))
                }
                return CTParagraphStyleCreate(settings, settings.count)
            }
        }
    }

    /// The height of one line of the style, for empty text.
    private static func emptyLineHeight(_ style: TextStyle) -> CGFloat {
        if let lineHeight = style.lineHeight { return CGFloat(lineHeight) }
        let font = font(for: style)
        return ceil(CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font))
    }

    private static func cgColor(_ color: Color) -> CGColor {
        let c = color.components
        return CGColor(srgbRed: c.red, green: c.green, blue: c.blue, alpha: c.alpha)
    }
}
