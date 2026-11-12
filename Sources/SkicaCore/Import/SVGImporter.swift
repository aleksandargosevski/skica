import CoreGraphics
import CoreText
import Foundation

/// Turns SVG into editable layers: shapes, paths, groups, text and embedded images, with fills,
/// gradients, strokes and opacity. Clip paths, masks, filters and patterns are skipped.
public enum SVGImporter {
    /// The SVG's contents as one group named `name`, in SVG user units placed at 0,0.
    /// `baseURL` resolves relative image references.
    public static func clipboard(from data: Data, name: String = "SVG", baseURL: URL? = nil) throws -> LayerClipboard {
        let root = try SVGElement.parse(data)
        var importer = Importer(root: root, baseURL: baseURL)
        let group = importer.importDocument(name: name)
        let roots = importer.tree.finish([group])
        guard !roots.isEmpty else { throw ImportError.invalid("The SVG has nothing that can be imported.") }
        return importer.tree.clipboard(roots: roots)
    }

    /// The SVG's canvas size (from `width`/`height` or the view box), if it declares one.
    public static func canvasSize(of data: Data) -> CGSize? {
        guard let root = try? SVGElement.parse(data) else { return nil }
        return Importer.viewport(of: root).size
    }
}

// MARK: - XML

final class SVGElement {
    let name: String
    var attributes: [String: String]
    var children: [SVGElement] = []
    var text = ""
    weak var parent: SVGElement?

    init(name: String, attributes: [String: String]) {
        self.name = name
        self.attributes = attributes
    }

    static func parse(_ data: Data) throws -> SVGElement {
        let delegate = TreeBuilder()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        guard parser.parse(), let root = delegate.root else {
            let reason = parser.parserError?.localizedDescription ?? "not XML"
            throw ImportError.invalid("This is not a valid SVG file (\(reason)).")
        }
        guard root.name == "svg" else { throw ImportError.invalid("This XML file is not an SVG image.") }
        return root
    }

    var descendants: [SVGElement] {
        children + children.flatMap(\.descendants)
    }

    private final class TreeBuilder: NSObject, XMLParserDelegate {
        var root: SVGElement?
        private var stack: [SVGElement] = []

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                    attributes: [String: String] = [:]) {
            // Namespaced names like svg:rect and xlink:href lose their prefix, except xlink:href's meaning.
            let local = name.split(separator: ":").last.map(String.init) ?? name
            var attributes = attributes
            if let href = attributes["xlink:href"], attributes["href"] == nil { attributes["href"] = href }
            let element = SVGElement(name: local, attributes: attributes)
            element.parent = stack.last
            stack.last?.children.append(element)
            if root == nil { root = element }
            stack.append(element)
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            stack.removeLast()
        }

        /// Text is kept as a whole and, for mixed content like `a <tspan>b</tspan> c`, as `#text` children in order.
        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard let element = stack.last else { return }
            element.text += string
            if let last = element.children.last, last.name == "#text" {
                last.text += string
            } else {
                let node = SVGElement(name: "#text", attributes: [:])
                node.text = string
                node.parent = element
                element.children.append(node)
            }
        }

        func parser(_ parser: XMLParser, foundCDATA data: Data) {
            stack.last?.text += String(decoding: data, as: UTF8.self)
        }
    }
}

// MARK: - Styles

/// Inherited presentation properties while walking the tree.
private struct SVGStyle {
    enum Paint {
        case none
        case color(Color)
        case reference(String)
    }

    var fill: Paint = .color(.black)
    var stroke: Paint = .none
    var strokeWidth = 1.0
    var fillOpacity = 1.0
    var strokeOpacity = 1.0
    var fillRule = VectorPath.FillRule.nonZero
    var lineCap = Border.Cap.butt
    var lineJoin = Border.Join.miter
    var dashes: [Double] = []
    var color = Color.black
    var fontFamily = "Helvetica"
    var fontSize = 16.0
    var fontWeight = 400
    var italic = false
    var textAnchor = "start"
    var isHidden = false

    /// Applies one element's properties (already merged from attributes, CSS and `style`).
    mutating func apply(_ properties: [String: String]) {
        if let value = properties["color"], let color = CSSColor.parse(value) { self.color = color }
        if let value = properties["fill"] { fill = paint(value) ?? fill }
        if let value = properties["stroke"] { stroke = paint(value) ?? stroke }
        if let value = properties["stroke-width"].flatMap(SVGLength.parse) { strokeWidth = value }
        if let value = properties["fill-opacity"].flatMap(SVGLength.fraction) { fillOpacity = value }
        if let value = properties["stroke-opacity"].flatMap(SVGLength.fraction) { strokeOpacity = value }
        if let value = properties["fill-rule"] { fillRule = value == "evenodd" ? .evenOdd : .nonZero }
        if let value = properties["stroke-linecap"], let cap = Border.Cap(rawValue: value) { lineCap = cap }
        if let value = properties["stroke-linejoin"] { lineJoin = value == "round" ? .round : value == "bevel" ? .bevel : .miter }
        if let value = properties["stroke-dasharray"] { dashes = value == "none" ? [] : NumberScanner.numbers(in: value) }
        if let value = properties["font-family"] {
            fontFamily = value.split(separator: ",").first.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " '\"")) } ?? fontFamily
        }
        if let value = properties["font-size"].flatMap(SVGLength.parse) { fontSize = value }
        if let value = properties["font-weight"] {
            switch value {
            case "normal": fontWeight = 400
            case "bold": fontWeight = 700
            case "bolder": fontWeight = min(fontWeight + 300, 900)
            case "lighter": fontWeight = max(fontWeight - 300, 100)
            default: fontWeight = Int(value) ?? fontWeight
            }
        }
        if let value = properties["font-style"] { italic = value == "italic" || value == "oblique" }
        if let value = properties["text-anchor"] { textAnchor = value }
        if let value = properties["visibility"] { isHidden = value == "hidden" || value == "collapse" }
    }

    private func paint(_ value: String) -> Paint? {
        let value = value.trimmingCharacters(in: .whitespaces)
        if value == "none" { return Paint.none }
        if value == "currentColor" { return .color(color) }
        if value.hasPrefix("url(") {
            let reference = value.dropFirst(4).prefix { $0 != ")" }.trimmingCharacters(in: CharacterSet(charactersIn: "#'\" "))
            return .reference(reference)
        }
        return CSSColor.parse(value).map(Paint.color)
    }
}

enum SVGLength {
    /// A length in user units; `pt`, `mm`, `cm`, `in` and `em` are converted, `%` is not supported.
    static func parse(_ text: String) -> Double? {
        let value = text.trimmingCharacters(in: .whitespaces)
        let units: [(String, Double)] = [("px", 1), ("pt", 4.0 / 3), ("pc", 16), ("mm", 96 / 25.4), ("cm", 96 / 2.54), ("in", 96), ("em", 16)]
        for (unit, factor) in units where value.hasSuffix(unit) {
            return Double(value.dropLast(unit.count)).map { $0 * factor }
        }
        if value.hasSuffix("%") { return nil }
        return Double(value)
    }

    /// `0.5` or `50%` as 0.5.
    static func fraction(_ text: String) -> Double? {
        let value = text.trimmingCharacters(in: .whitespaces)
        if value.hasSuffix("%") { return Double(value.dropLast()).map { $0 / 100 } }
        return Double(value)
    }
}

/// Simple CSS from `<style>`: rules with tag, `.class` and `#id` selectors (comma lists allowed).
private struct StyleSheet {
    private var rules: [(selector: String, specificity: Int, properties: [String: String])] = []

    init(_ css: String) {
        let withoutComments = css.replacingOccurrences(of: #"/\*[\s\S]*?\*/"#, with: "", options: .regularExpression)
        for block in withoutComments.split(separator: "}") {
            let parts = block.split(separator: "{", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let properties = Self.declarations(String(parts[1]))
            for selector in parts[0].split(separator: ",") {
                let selector = selector.trimmingCharacters(in: .whitespacesAndNewlines)
                let specificity = selector.hasPrefix("#") ? 3 : selector.hasPrefix(".") ? 2 : 1
                rules.append((selector, specificity, properties))
            }
        }
    }

    /// `fill: red; stroke: blue` as a dictionary.
    static func declarations(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for declaration in text.split(separator: ";") {
            let pair = declaration.split(separator: ":", maxSplits: 1)
            guard pair.count == 2 else { continue }
            let key = pair[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = pair[1].replacingOccurrences(of: "!important", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
            result[key] = value
        }
        return result
    }

    func properties(for element: SVGElement) -> [String: String] {
        let classes = Set((element.attributes["class"] ?? "").split(separator: " ").map { "." + $0 })
        let id = element.attributes["id"].map { "#" + $0 }
        var result: [String: String] = [:]
        for rule in rules.sorted(by: { $0.specificity < $1.specificity }) {
            let matches = rule.selector == element.name || classes.contains(rule.selector) || rule.selector == id
                || (rule.selector.contains(".") && !rule.selector.hasPrefix(".")
                    && rule.selector.split(separator: ".").first.map(String.init) == element.name
                    && classes.contains("." + rule.selector.split(separator: ".").dropFirst().joined(separator: ".")))
            if matches { result.merge(rule.properties) { _, new in new } }
        }
        return result
    }
}

// MARK: - Importer

private struct Importer {
    static let presentationAttributes: Set<String> = [
        "fill", "stroke", "stroke-width", "fill-opacity", "stroke-opacity", "fill-rule", "stroke-linecap", "stroke-linejoin",
        "stroke-dasharray", "color", "font-family", "font-size", "font-weight", "font-style", "text-anchor", "visibility",
        "opacity", "display",
    ]
    static let skipped: Set<String> = [
        "defs", "clipPath", "mask", "symbol", "style", "title", "desc", "metadata", "linearGradient", "radialGradient",
        "pattern", "filter", "marker", "script", "foreignObject", "#text",
    ]

    let root: SVGElement
    let baseURL: URL?
    let styleSheet: StyleSheet
    let elementsByID: [String: SVGElement]
    var tree = ImportTree()
    private var useDepth = 0

    init(root: SVGElement, baseURL: URL?) {
        self.root = root
        self.baseURL = baseURL
        let all = [root] + root.descendants
        styleSheet = StyleSheet(all.filter { $0.name == "style" }.map(\.text).joined(separator: "\n"))
        var byID: [String: SVGElement] = [:]
        for element in all { if let id = element.attributes["id"], byID[id] == nil { byID[id] = element } }
        elementsByID = byID
    }

    /// The SVG's size and the transform from its view box into it.
    static func viewport(of element: SVGElement) -> (size: CGSize?, transform: CGAffineTransform) {
        let width = element.attributes["width"].flatMap(SVGLength.parse)
        let height = element.attributes["height"].flatMap(SVGLength.parse)
        let viewBox = element.attributes["viewBox"].map(NumberScanner.numbers(in:)).flatMap { $0.count == 4 ? $0 : nil }
        guard let viewBox, viewBox[2] > 0, viewBox[3] > 0 else {
            return (width.flatMap { w in height.map { CGSize(width: w, height: $0) } }, .identity)
        }
        let size = CGSize(width: width ?? viewBox[2], height: height ?? viewBox[3])
        let aspect = element.attributes["preserveAspectRatio"] ?? ""
        var scaleX = size.width / viewBox[2]
        var scaleY = size.height / viewBox[3]
        var dx = 0.0
        var dy = 0.0
        if !aspect.hasPrefix("none") {
            let scale = aspect.contains("slice") ? max(scaleX, scaleY) : min(scaleX, scaleY)
            let extraX = size.width - viewBox[2] * scale
            let extraY = size.height - viewBox[3] * scale
            dx = aspect.contains("xMin") ? 0 : aspect.contains("xMax") ? extraX : extraX / 2
            dy = aspect.contains("YMin") ? 0 : aspect.contains("YMax") ? extraY : extraY / 2
            scaleX = scale
            scaleY = scale
        }
        let transform = CGAffineTransform(translationX: dx, y: dy).scaledBy(x: scaleX, y: scaleY).translatedBy(x: -viewBox[0], y: -viewBox[1])
        return (size, transform)
    }

    mutating func importDocument(name: String) -> LayerID {
        let group = tree.add(Layer(name: name, kind: .group, frame: Rect(x: 0, y: 0, width: 0, height: 0)), to: nil)
        var style = SVGStyle()
        style.apply(properties(of: root))
        let transform = Self.viewport(of: root).transform
        for child in root.children { visit(child, transform: transform, style: style, parent: group) }
        return group
    }

    /// Presentation attributes, then CSS rules, then the `style` attribute.
    private func properties(of element: SVGElement) -> [String: String] {
        var result = element.attributes.filter { Self.presentationAttributes.contains($0.key) }
        result.merge(styleSheet.properties(for: element)) { _, new in new }
        if let inline = element.attributes["style"] { result.merge(StyleSheet.declarations(inline)) { _, new in new } }
        return result
    }

    private mutating func visit(_ element: SVGElement, transform parentTransform: CGAffineTransform, style parentStyle: SVGStyle, parent: LayerID) {
        guard !Self.skipped.contains(element.name) else { return }
        let properties = properties(of: element)
        if properties["display"] == "none" { return }
        var style = parentStyle
        style.apply(properties)
        var transform = parentTransform
        if let value = element.attributes["transform"] { transform = SVGTransform.parse(value).concatenating(transform) }
        let opacity = properties["opacity"].flatMap(SVGLength.fraction) ?? 1
        let name = element.attributes["id"] ?? element.attributes["inkscape:label"]

        switch element.name {
        case "g", "a", "switch", "svg":
            if element.name == "svg" {
                let x = element.attributes["x"].flatMap(SVGLength.parse) ?? 0
                let y = element.attributes["y"].flatMap(SVGLength.parse) ?? 0
                transform = Self.viewport(of: element).transform.concatenating(CGAffineTransform(translationX: x, y: y)).concatenating(transform)
            }
            var group = Layer(name: name ?? "Group", kind: .group, frame: Rect(x: 0, y: 0, width: 0, height: 0))
            group.opacity = opacity
            group.isVisible = !style.isHidden
            let id = tree.add(group, to: parent)
            for child in element.children { visit(child, transform: transform, style: style, parent: id) }
        case "use":
            guard useDepth < 8, let href = element.attributes["href"], href.hasPrefix("#"),
                  let target = elementsByID[String(href.dropFirst())] else { return }
            let x = element.attributes["x"].flatMap(SVGLength.parse) ?? 0
            let y = element.attributes["y"].flatMap(SVGLength.parse) ?? 0
            transform = CGAffineTransform(translationX: x, y: y).concatenating(transform)
            var group = Layer(name: name ?? target.attributes["id"] ?? "Use", kind: .group, frame: Rect(x: 0, y: 0, width: 0, height: 0))
            group.opacity = opacity
            let id = tree.add(group, to: parent)
            useDepth += 1
            if target.name == "symbol" {
                transform = Self.viewport(of: target).transform.concatenating(transform)
                for child in target.children { visit(child, transform: transform, style: style, parent: id) }
            } else {
                visit(target, transform: transform, style: style, parent: id)
            }
            useDepth -= 1
        case "text":
            addText(element, transform: transform, style: style, opacity: opacity, name: name, parent: parent)
        case "image":
            addImage(element, transform: transform, opacity: opacity, name: name, parent: parent)
        default:
            addShape(element, transform: transform, style: style, opacity: opacity, name: name, parent: parent)
        }
    }

    // MARK: Shapes

    private mutating func addShape(_ element: SVGElement, transform: CGAffineTransform, style: SVGStyle, opacity: Double, name: String?, parent: LayerID) {
        let number = { (key: String) in element.attributes[key].flatMap(SVGLength.parse) ?? 0 }
        let axisAligned = transform.b == 0 && transform.c == 0 && transform.a > 0 && transform.d > 0
        var layer: Layer
        switch element.name {
        case "rect":
            let rect = CGRect(x: number("x"), y: number("y"), width: number("width"), height: number("height"))
            guard rect.width > 0, rect.height > 0 else { return }
            var rx = element.attributes["rx"].flatMap(SVGLength.parse)
            var ry = element.attributes["ry"].flatMap(SVGLength.parse)
            rx = rx ?? ry
            ry = ry ?? rx
            let radiusX = min(rx ?? 0, rect.width / 2)
            let radiusY = min(ry ?? 0, rect.height / 2)
            if axisAligned, abs(radiusX * transform.a - radiusY * transform.d) < 0.01 {
                layer = Layer(name: name ?? "Rectangle", kind: .rectangle(cornerRadius: radiusX * transform.a), frame: Rect(rect.applying(transform)))
            } else {
                let path = CGPath(roundedRect: rect, cornerWidth: radiusX, cornerHeight: radiusY, transform: nil)
                guard let pathLayer = Self.pathLayer(path, transform: transform, name: name ?? "Rectangle", fillRule: style.fillRule) else { return }
                layer = pathLayer
            }
        case "circle", "ellipse":
            let rx = element.name == "circle" ? number("r") : number("rx")
            let ry = element.name == "circle" ? number("r") : number("ry")
            guard rx > 0, ry > 0 else { return }
            let rect = CGRect(x: number("cx") - rx, y: number("cy") - ry, width: rx * 2, height: ry * 2)
            if axisAligned {
                layer = Layer(name: name ?? (element.name == "circle" ? "Circle" : "Ellipse"), kind: .oval, frame: Rect(rect.applying(transform)))
            } else {
                guard let pathLayer = Self.pathLayer(CGPath(ellipseIn: rect, transform: nil), transform: transform, name: name ?? "Ellipse",
                                                     fillRule: style.fillRule) else { return }
                layer = pathLayer
            }
        case "line":
            let path = CGMutablePath()
            path.move(to: CGPoint(x: number("x1"), y: number("y1")))
            path.addLine(to: CGPoint(x: number("x2"), y: number("y2")))
            guard let pathLayer = Self.pathLayer(path, transform: transform, name: name ?? "Line", fillRule: style.fillRule) else { return }
            layer = pathLayer
        case "polyline", "polygon":
            let values = NumberScanner.numbers(in: element.attributes["points"] ?? "")
            guard values.count >= 4 else { return }
            let path = CGMutablePath()
            path.move(to: CGPoint(x: values[0], y: values[1]))
            for index in stride(from: 2, to: values.count - 1, by: 2) { path.addLine(to: CGPoint(x: values[index], y: values[index + 1])) }
            if element.name == "polygon" { path.closeSubpath() }
            guard let pathLayer = Self.pathLayer(path, transform: transform, name: name ?? (element.name == "polygon" ? "Polygon" : "Polyline"),
                                                 fillRule: style.fillRule) else { return }
            layer = pathLayer
        case "path":
            let path = SVGPathData.path(element.attributes["d"] ?? "")
            guard !path.isEmpty, let pathLayer = Self.pathLayer(path, transform: transform, name: name ?? "Path", fillRule: style.fillRule) else { return }
            layer = pathLayer
        default:
            return
        }
        let isLine = element.name == "line" || element.name == "polyline"
        layer.style = shapeStyle(style, frame: layer.frame.cgRect, transform: transform, fills: !isLine || element.name == "polyline")
        layer.opacity = opacity
        layer.isVisible = !style.isHidden
        tree.add(layer, to: parent)
    }

    /// A path layer whose frame is the transformed path's bounds and whose points are relative to it.
    static func pathLayer(_ path: CGPath, transform: CGAffineTransform, name: String, fillRule: VectorPath.FillRule) -> Layer? {
        var matrix = transform
        guard let transformed = path.copy(using: &matrix), !transformed.isEmpty else { return nil }
        let bounds = transformed.boundingBoxOfPath
        guard bounds.width.isFinite, bounds.height.isFinite else { return nil }
        let vector = VectorPath(transformed, fillRule: fillRule).applying(CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY))
        return Layer(name: name, kind: .path(vector), frame: Rect(bounds))
    }

    private func shapeStyle(_ style: SVGStyle, frame: CGRect, transform: CGAffineTransform, fills: Bool) -> Style {
        var result = Style()
        if fills, let fill = fill(for: style.fill, opacity: style.fillOpacity, frame: frame, transform: transform) {
            result.fills = [fill]
        }
        if let stroke = fill(for: style.stroke, opacity: style.strokeOpacity, frame: frame, transform: transform), style.strokeWidth > 0 {
            let scale = sqrt(abs(transform.a * transform.d - transform.b * transform.c))
            result.borders = [Border(stroke.gradient?.stops.first?.color ?? stroke.color, width: style.strokeWidth * scale, position: .center,
                                     dashes: style.dashes.map { $0 * scale }, cap: style.lineCap, join: style.lineJoin)]
        }
        return result
    }

    private func fill(for paint: SVGStyle.Paint, opacity: Double, frame: CGRect, transform: CGAffineTransform) -> Fill? {
        switch paint {
        case .none:
            return nil
        case .color(let color):
            return Fill(Self.multiplied(color, by: opacity))
        case .reference(let id):
            guard let gradient = gradient(id, frame: frame, transform: transform, opacity: opacity) else { return nil }
            return Fill(gradient.stops.first?.color ?? .black, gradient: gradient)
        }
    }

    /// A gradient in unit coordinates of the shape's frame.
    private func gradient(_ id: String, frame: CGRect, transform: CGAffineTransform, opacity: Double) -> Gradient? {
        guard let element = elementsByID[id], element.name == "linearGradient" || element.name == "radialGradient" else { return nil }
        // Attributes and stops may come from gradients this one references.
        var chain = [element]
        while chain.count < 8, let href = chain.last?.attributes["href"], href.hasPrefix("#"), let next = elementsByID[String(href.dropFirst())] {
            chain.append(next)
        }
        func attribute(_ key: String) -> String? { chain.lazy.compactMap { $0.attributes[key] }.first }
        let stopsElement = chain.first { $0.children.contains { $0.name == "stop" } }
        let stops: [GradientStop] = (stopsElement?.children ?? []).filter { $0.name == "stop" }.map { stop in
            let properties = stop.attributes.merging(stop.attributes["style"].map(StyleSheet.declarations) ?? [:]) { _, new in new }
            let base = properties["stop-color"].flatMap(CSSColor.parse) ?? .black
            let alpha = (properties["stop-opacity"].flatMap(SVGLength.fraction) ?? 1) * opacity
            return GradientStop(position: min(max(stop.attributes["offset"].flatMap(SVGLength.fraction) ?? 0, 0), 1),
                                color: Self.multiplied(base, by: alpha))
        }
        guard !stops.isEmpty else { return nil }

        let userSpace = attribute("gradientUnits") == "userSpaceOnUse"
        let gradientTransform = attribute("gradientTransform").map(SVGTransform.parse) ?? .identity
        func coordinate(_ key: String, _ fallback: Double, horizontal: Bool) -> Double {
            guard let text = attribute(key) else { return fallback }
            if text.hasSuffix("%") {
                let fraction = Double(text.dropLast()).map { $0 / 100 } ?? fallback
                return userSpace ? fraction * (horizontal ? frame.width : frame.height) : fraction
            }
            return Double(text) ?? fallback
        }
        func unit(_ point: CGPoint) -> UnitPoint {
            if userSpace {
                let page = point.applying(gradientTransform).applying(transform)
                return UnitPoint(x: frame.width > 0 ? (page.x - frame.minX) / frame.width : 0, y: frame.height > 0 ? (page.y - frame.minY) / frame.height : 0)
            }
            let local = point.applying(gradientTransform)
            return UnitPoint(x: local.x, y: local.y)
        }
        if element.name == "linearGradient" {
            let from = CGPoint(x: coordinate("x1", 0, horizontal: true), y: coordinate("y1", 0, horizontal: false))
            let to = CGPoint(x: coordinate("x2", userSpace ? frame.width : 1, horizontal: true), y: coordinate("y2", 0, horizontal: false))
            return Gradient(kind: .linear, from: unit(from), to: unit(to), stops: stops)
        }
        let half = userSpace ? 0 : 0.5
        let center = CGPoint(x: coordinate("cx", half, horizontal: true), y: coordinate("cy", half, horizontal: false))
        let radius = coordinate("r", half, horizontal: true)
        return Gradient(kind: .radial, from: unit(center), to: unit(CGPoint(x: center.x + radius, y: center.y)), stops: stops)
    }

    static func multiplied(_ color: Color, by opacity: Double) -> Color {
        var color = color
        color.alpha = UInt8(max(0, min(255, (Double(color.alpha) * opacity).rounded())))
        return color
    }

    // MARK: Text and images

    private mutating func addText(_ element: SVGElement, transform: CGAffineTransform, style: SVGStyle, opacity: Double, name: String?, parent: LayerID) {
        var runs: [TextRun] = []
        var origin = CGPoint(x: element.attributes["x"].map(NumberScanner.numbers(in:))?.first ?? 0,
                             y: element.attributes["y"].map(NumberScanner.numbers(in:))?.first ?? 0)
        var leading = style
        func collect(_ element: SVGElement, style: SVGStyle) {
            for child in element.children {
                if child.name == "#text" {
                    let text = child.text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                    if !text.isEmpty, !(runs.isEmpty && text == " ") { runs.append(TextRun(text: text, style: textStyle(style))) }
                    continue
                }
                guard child.name == "tspan" else { continue }
                var childStyle = style
                childStyle.apply(properties(of: child))
                if runs.isEmpty {
                    leading = childStyle
                    if let x = child.attributes["x"].map(NumberScanner.numbers(in:))?.first { origin.x = x }
                    if let y = child.attributes["y"].map(NumberScanner.numbers(in:))?.first { origin.y = y }
                }
                collect(child, style: childStyle)
            }
        }
        collect(element, style: style)
        guard !runs.isEmpty else { return }
        runs[0].text = String(runs[0].text.drop { $0 == " " })
        runs[runs.count - 1].text = String(runs[runs.count - 1].text.reversed().drop { $0 == " " }.reversed())

        // Only translation and uniform scale carry over to text.
        let scale = sqrt(abs(transform.a * transform.d - transform.b * transform.c))
        if scale != 1 {
            for index in runs.indices { runs[index].style.fontSize *= scale }
        }
        let content = TextContent(runs: runs, alignment: .left, sizing: .autoWidth).normalized()
        let size = TextLayout.size(of: content, width: nil)
        let ascent = CTFontGetAscent(TextLayout.font(for: content.leadingStyle))
        let baseline = origin.applying(transform)
        var x = baseline.x
        switch leading.textAnchor {
        case "middle": x -= size.width / 2
        case "end": x -= size.width
        default: break
        }
        var layer = Layer(name: name ?? String(content.string.prefix(40)), kind: .text(content),
                          frame: Rect(x: x, y: baseline.y - ascent, width: size.width, height: size.height))
        layer.opacity = opacity
        layer.isVisible = !style.isHidden
        tree.add(layer, to: parent)
    }

    private func textStyle(_ style: SVGStyle) -> TextStyle {
        let font = FontFaces.face(family: style.fontFamily, weight: style.fontWeight, italic: style.italic)
            ?? FontFaces.face(family: "Helvetica Neue", weight: style.fontWeight, italic: style.italic)
            ?? TextStyle.defaultFont
        var color = Color.black
        if case .color(let fill) = style.fill { color = Self.multiplied(fill, by: style.fillOpacity) }
        return TextStyle(fontName: font, fontSize: style.fontSize, color: color)
    }

    private mutating func addImage(_ element: SVGElement, transform: CGAffineTransform, opacity: Double, name: String?, parent: LayerID) {
        guard let href = element.attributes["href"], let data = imageData(href) else { return }
        let natural = ImageData.naturalSize(of: data) ?? CGSize(width: 100, height: 100)
        let width = element.attributes["width"].flatMap(SVGLength.parse) ?? natural.width
        let height = element.attributes["height"].flatMap(SVGLength.parse) ?? natural.height
        let rect = CGRect(x: element.attributes["x"].flatMap(SVGLength.parse) ?? 0, y: element.attributes["y"].flatMap(SVGLength.parse) ?? 0,
                          width: width, height: height).applying(transform)
        let hash = tree.addImage(data)
        var layer = Layer(name: name ?? "Image", kind: .image(hash: hash), frame: Rect(rect))
        layer.opacity = opacity
        tree.add(layer, to: parent)
    }

    private func imageData(_ href: String) -> Data? {
        if href.hasPrefix("data:") {
            guard let comma = href.firstIndex(of: ",") else { return nil }
            let header = href[..<comma]
            let payload = String(href[href.index(after: comma)...])
            if header.contains(";base64") {
                return Data(base64Encoded: payload.filter { !$0.isWhitespace })
            }
            return payload.removingPercentEncoding.map { Data($0.utf8) }
        }
        guard let baseURL, let url = URL(string: href, relativeTo: baseURL), url.isFileURL else { return nil }
        return try? Data(contentsOf: url)
    }
}

/// The `transform` attribute: matrix, translate, scale, rotate, skewX and skewY, applied left to right.
enum SVGTransform {
    static func parse(_ text: String) -> CGAffineTransform {
        var result = CGAffineTransform.identity
        var remaining = Substring(text)
        while let open = remaining.firstIndex(of: "("), let close = remaining[open...].firstIndex(of: ")") {
            let name = remaining[..<open].trimmingCharacters(in: CharacterSet(charactersIn: " ,\n\t"))
            let values = NumberScanner.numbers(in: String(remaining[remaining.index(after: open)..<close]))
            let value = { (index: Int, fallback: Double) in values.count > index ? values[index] : fallback }
            var transform = CGAffineTransform.identity
            switch name {
            case "matrix" where values.count == 6:
                transform = CGAffineTransform(a: values[0], b: values[1], c: values[2], d: values[3], tx: values[4], ty: values[5])
            case "translate":
                transform = CGAffineTransform(translationX: value(0, 0), y: value(1, 0))
            case "scale":
                transform = CGAffineTransform(scaleX: value(0, 1), y: value(1, value(0, 1)))
            case "rotate":
                let angle = value(0, 0) * .pi / 180
                let center = CGPoint(x: value(1, 0), y: value(2, 0))
                transform = CGAffineTransform(translationX: center.x, y: center.y).rotated(by: angle).translatedBy(x: -center.x, y: -center.y)
            case "skewX":
                transform = CGAffineTransform(a: 1, b: 0, c: tan(value(0, 0) * .pi / 180), d: 1, tx: 0, ty: 0)
            case "skewY":
                transform = CGAffineTransform(a: 1, b: tan(value(0, 0) * .pi / 180), c: 0, d: 1, tx: 0, ty: 0)
            default:
                break
            }
            // Later transforms apply first (they are closer to the element).
            result = transform.concatenating(result)
            remaining = remaining[remaining.index(after: close)...]
        }
        return result
    }
}
