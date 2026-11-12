import CoreGraphics
import CoreText
import Foundation

/// Imports Figma files through the REST API (a personal access token is needed): pages, frames,
/// groups, shapes and vectors (from their geometry), text with styled runs, image fills,
/// components as symbols and instances with their overrides, auto layout, constraints,
/// effects and export settings. Prototyping, comments and plugin data are left out.
public enum FigmaImporter {
    /// The file key of a figma.com link (`/file/KEY/…`, `/design/KEY/…`) or a bare key.
    public static func fileKey(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed), let host = url.host, host.hasSuffix("figma.com") {
            let parts = url.pathComponents
            guard let index = parts.firstIndex(where: { ["file", "design", "proto", "board"].contains($0) }), index + 1 < parts.count else { return nil }
            return parts[index + 1]
        }
        let isKey = !trimmed.isEmpty && trimmed.allSatisfy { $0.isLetter || $0.isNumber }
        return isKey ? trimmed : nil
    }

    /// Downloads a file and its images and converts it.
    public static func document(fileKey: String, token: String, session: URLSession = .shared) async throws -> Document {
        let file = try await request("files/\(fileKey)?geometry=paths", token: token, session: session)
        let references = try await request("files/\(fileKey)/images", token: token, session: session)
        let urls = ((try JSONSerialization.jsonObject(with: references) as? [String: Any])?["meta"] as? [String: Any])?["images"] as? [String: String] ?? [:]
        let used = usedImageReferences(in: file)
        var images: [String: Data] = [:]
        try await withThrowingTaskGroup(of: (String, Data?).self) { group in
            for (reference, link) in urls where used.contains(reference) {
                guard let url = URL(string: link) else { continue }
                group.addTask {
                    // A missing image should not stop the import; the layer stays without it.
                    let data = try? await session.data(from: url).0
                    return (reference, data)
                }
            }
            for try await (reference, data) in group {
                if let data { images[reference] = data }
            }
        }
        return try document(fromFile: file, images: images)
    }

    /// Converts the JSON of `GET /v1/files/:key?geometry=paths`; `images` maps image refs to bytes.
    public static func document(fromFile data: Data, images: [String: Data] = [:]) throws -> Document {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let root = json["document"] as? [String: Any] else {
            throw ImportError.invalid("Figma returned something that is not a file.")
        }
        var importer = Importer(images: images)
        let document = importer.importDocument(root)
        try document.validate()
        return document
    }

    private static func request(_ path: String, token: String, session: URLSession) async throws -> Data {
        guard let url = URL(string: "https://api.figma.com/v1/\(path)") else { throw ImportError.invalid("Invalid Figma file key.") }
        var request = URLRequest(url: url)
        request.setValue(token, forHTTPHeaderField: "X-Figma-Token")
        request.timeoutInterval = 120
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ImportError.invalid("Could not reach Figma: \(error.localizedDescription)")
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200: return data
        case 403: throw ImportError.invalid("Figma refused the token. Check that it is valid and can read files.")
        case 404: throw ImportError.invalid("Figma has no such file, or the token's account cannot open it.")
        case 429: throw ImportError.invalid("Figma's rate limit was reached. Try again in a minute.")
        default:
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["err"] as? String
            throw ImportError.invalid("Figma answered with error \(status)\(message.map { ": \($0)" } ?? "").")
        }
    }

    private static func usedImageReferences(in data: Data) -> Set<String> {
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        let pattern = try? NSRegularExpression(pattern: #""imageRef"\s*:\s*"([^"]+)""#)
        let range = NSRange(text.startIndex..., in: text)
        return Set(pattern?.matches(in: text, range: range).compactMap { match in
            Range(match.range(at: 1), in: text).map { String(text[$0]) }
        } ?? [])
    }
}

private typealias JSON = [String: Any]

private extension Dictionary where Key == String, Value == Any {
    func string(_ key: String) -> String? { self[key] as? String }
    func number(_ key: String) -> Double? { (self[key] as? NSNumber)?.doubleValue }
    func bool(_ key: String, default value: Bool = false) -> Bool { (self[key] as? NSNumber)?.boolValue ?? value }
    func object(_ key: String) -> JSON? { self[key] as? JSON }
    func objects(_ key: String) -> [JSON] { self[key] as? [JSON] ?? [] }
    var type: String { string("type") ?? "" }
    var isVisible: Bool { bool("visible", default: true) }
}

private struct Importer {
    let images: [String: Data]
    var tree = ImportTree()
    var document = Document(pages: [], layers: [:])
    /// Every component in the file by ID, to tell what an instance changed.
    private var components: [String: JSON] = [:]
    private var componentSetNames: [String: String] = [:]
    private var usedIDs = Set<LayerID>()

    init(images: [String: Data]) {
        self.images = images
    }

    mutating func importDocument(_ root: JSON) -> Document {
        collectComponents(root, setName: nil)
        for canvas in root.objects("children") where canvas.type == "CANVAS" {
            var page = Page(name: canvas.string("name") ?? "Page")
            var roots: [LayerID] = []
            var masters: [LayerID] = []
            for child in canvas.objects("children") {
                roots += importNode(child, parent: nil, topLevel: true, masters: &masters)
            }
            page.layers = tree.finish(roots + masters)
            document.pages.append(page)
        }
        if document.pages.isEmpty { document.pages = [Page(name: "Page 1")] }
        document.layers = tree.layers
        document.images = tree.images
        return document
    }

    private mutating func collectComponents(_ node: JSON, setName: String?) {
        if node.type == "COMPONENT", let id = node.string("id") {
            components[id] = node
            if let setName { componentSetNames[id] = setName }
        }
        let name = node.type == "COMPONENT_SET" ? node.string("name") : setName
        for child in node.objects("children") { collectComponents(child, setName: name) }
    }

    // MARK: Nodes

    /// The layers for one node: none, one, or (for components inside other nodes) a master
    /// added to `masters`, since masters live at the top of a page.
    private mutating func importNode(_ node: JSON, parent: LayerID?, topLevel: Bool, masters: inout [LayerID]) -> [LayerID] {
        let type = node.type
        let name = node.string("name") ?? type.capitalized
        let frame = Self.frame(node)
        var layer: Layer
        var children = node.objects("children")

        switch type {
        case "COMPONENT":
            let symbolName = componentSetNames[node.string("id") ?? ""].map { "\($0)/\(name)" } ?? name
            layer = Layer(name: symbolName, kind: .symbolMaster(SymbolID(node.string("id") ?? UUID().uuidString)), frame: frame,
                          style: Style(fills: fills(node.objects("fills"))))
            if !topLevel {
                // Masters move to the top of the page, keeping their place on the canvas.
                let id = add(layer, node: node, parent: nil)
                for child in children { _ = importNode(child, parent: id, topLevel: false, masters: &masters) }
                masters.append(id)
                return []
            }
        case "COMPONENT_SET":
            // Its variants become separate symbols; the set itself is only a container.
            for child in children { masters += importNode(child, parent: nil, topLevel: true, masters: &masters) }
            return []
        case "FRAME" where topLevel, "SECTION" where topLevel:
            layer = Layer(name: name, kind: .artboard, frame: frame, style: Style(fills: fills(node.objects("fills"))))
            layer.stack = stack(node)
        case "FRAME", "SECTION":
            layer = Layer(name: name, kind: .group, frame: Rect(x: 0, y: 0, width: 0, height: 0))
            let background = shapeStyle(node)
            let hasBackground = !background.fills.isEmpty || !background.borders.isEmpty || !background.shadows.isEmpty
            if hasBackground || node.bool("clipsContent") {
                // A nested frame's look and clipping come from a rectangle at the bottom of the group.
                var rectangle = Layer(name: "Background", kind: .rectangle(cornerRadius: node.number("cornerRadius") ?? 0), frame: frame, style: background)
                rectangle.isMask = node.bool("clipsContent")
                rectangle.rotation = Self.rotation(node)
                children.insert(["__layer": rectangle], at: 0)
            } else {
                layer.stack = stack(node)
            }
        case _ where type == "GROUP" || (type == "BOOLEAN_OPERATION" && node.objects("fillGeometry").isEmpty):
            layer = Layer(name: name, kind: .group, frame: Rect(x: 0, y: 0, width: 0, height: 0))
        case "INSTANCE":
            if let componentID = node.string("componentId"), let component = components[componentID] {
                layer = Layer(name: name, kind: .symbolInstance(SymbolInstance(symbolID: SymbolID(componentID),
                                                                               overrides: overrides(instance: node, component: component))),
                              frame: frame)
                children = []
            } else {
                // Components from libraries are not in the file; the instance's resolved layers are.
                layer = Layer(name: name, kind: .group, frame: Rect(x: 0, y: 0, width: 0, height: 0))
            }
        case "TEXT":
            layer = Layer(name: name, kind: .text(text(node)), frame: frame)
        case "RECTANGLE" where uniformRadius(node) != nil:
            layer = Layer(name: name, kind: .rectangle(cornerRadius: uniformRadius(node) ?? 0), frame: frame, style: shapeStyle(node))
        case "ELLIPSE" where node.object("arcData").map(Self.isFullEllipse) ?? true:
            layer = Layer(name: name, kind: .oval, frame: frame, style: shapeStyle(node))
        case "RECTANGLE", "ELLIPSE", "VECTOR", "STAR", "LINE", "REGULAR_POLYGON", "BOOLEAN_OPERATION":
            guard let shape = vectorLayer(node, frame: frame, name: name) else { return [] }
            layer = shape
            children = []
        default:
            return []
        }

        let imageFill = node.objects("fills").last { $0.isVisible && $0.type == "IMAGE" }
        let id: LayerID
        if let imageFill, !layer.isContainer, layer.symbolInstance == nil, layer.textContent == nil,
           let reference = imageFill.string("imageRef"), let data = images[reference] {
            // The shape clips the image; both sit in a group named after the node.
            var group = Layer(name: name, kind: .group, frame: Rect(x: 0, y: 0, width: 0, height: 0))
            group.opacity = node.number("opacity") ?? 1
            let groupID = add(group, node: nil, parent: parent)
            layer.isMask = true
            layer.name = "Shape"
            add(layer, node: node, parent: groupID, keepsOpacity: false)
            var image = Layer(name: "Image", kind: .image(hash: tree.addImage(data)), frame: layer.frame)
            image.rotation = layer.rotation
            add(image, node: nil, parent: groupID)
            id = groupID
        } else {
            id = add(layer, node: node, parent: parent)
        }
        for child in children {
            if let extra = child["__layer"] as? Layer {
                add(extra, node: nil, parent: id)
            } else {
                _ = importNode(child, parent: id, topLevel: false, masters: &masters)
            }
        }
        return [id]
    }

    /// Adds a layer with the node's common properties (ID, visibility, opacity, effects…).
    @discardableResult
    private mutating func add(_ layer: Layer, node: JSON?, parent: LayerID?, keepsOpacity: Bool = true) -> LayerID {
        var layer = layer
        if let node {
            var id = LayerID(node.string("id") ?? UUID().uuidString)
            if usedIDs.contains(id) { id = .make() }
            layer.id = id
            layer.isVisible = node.isVisible
            layer.isLocked = node.bool("locked")
            if node.bool("isMask") { layer.isMask = true }
            if keepsOpacity { layer.opacity = node.number("opacity") ?? 1 }
            layer.rotation = Self.rotation(node)
            layer.style.blendMode = Self.blendMode(node.string("blendMode"))
            layer.constraints = constraints(node.object("constraints"))
            layer.exports = exports(node.objects("exportSettings"))
            if layer.textContent == nil, !layer.isContainer || layer.isArtboard {
                let effects = self.effects(node.objects("effects"))
                layer.style.shadows = effects.shadows
                layer.style.innerShadows = effects.innerShadows
                layer.style.blur = effects.blur
            }
        }
        usedIDs.insert(layer.id)
        return tree.add(layer, to: parent)
    }

    // MARK: Geometry

    /// The unrotated frame in page coordinates: the node's size around the center of its bounds.
    static func frame(_ node: JSON) -> Rect {
        let box = node.object("absoluteBoundingBox")
        let size = node.object("size")
        let width = size?.number("x") ?? box?.number("width") ?? 0
        let height = size?.number("y") ?? box?.number("height") ?? 0
        let centerX = (box?.number("x") ?? 0) + (box?.number("width") ?? width) / 2
        let centerY = (box?.number("y") ?? 0) + (box?.number("height") ?? height) / 2
        return Rect(x: centerX - width / 2, y: centerY - height / 2, width: width, height: height)
    }

    /// Clockwise degrees from `relativeTransform` ([[a, c, tx], [b, d, ty]]).
    static func rotation(_ node: JSON) -> Double {
        guard let rows = node["relativeTransform"] as? [[NSNumber]], rows.count == 2, rows[0].count == 3 else { return 0 }
        let angle = atan2(rows[1][0].doubleValue, rows[0][0].doubleValue) * 180 / .pi
        return abs(angle) < 0.01 ? 0 : (angle * 100).rounded() / 100
    }

    private func uniformRadius(_ node: JSON) -> Double? {
        if let corners = node["rectangleCornerRadii"] as? [NSNumber] {
            let values = Set(corners.map(\.doubleValue))
            return values.count == 1 ? values.first : nil
        }
        return node.number("cornerRadius") ?? 0
    }

    private static func isFullEllipse(_ arc: JSON) -> Bool {
        let start = arc.number("startingAngle") ?? 0
        let end = arc.number("endingAngle") ?? 2 * .pi
        return abs(end - start - 2 * .pi) < 0.001 && (arc.number("innerRadius") ?? 0) == 0
    }

    /// A shape from its fill geometry (or, for lines and open paths, its stroke outline).
    private func vectorLayer(_ node: JSON, frame: Rect, name: String) -> Layer? {
        let geometry = node.objects("fillGeometry")
        var style = shapeStyle(node)
        let path = CGMutablePath()
        var rule = VectorPath.FillRule.nonZero
        for entry in geometry {
            path.addPath(SVGPathData.path(entry.string("path") ?? ""))
            if entry.string("windingRule") == "EVENODD" { rule = .evenOdd }
        }
        if path.isEmpty {
            if node.type == "LINE" {
                path.move(to: .zero)
                path.addLine(to: CGPoint(x: frame.width, y: 0))
            } else {
                // Open paths have no fill geometry; their stroke outline is drawn filled.
                for entry in node.objects("strokeGeometry") { path.addPath(SVGPathData.path(entry.string("path") ?? "")) }
                guard !path.isEmpty, let stroke = style.borders.first else { return nil }
                style.fills = [Fill(stroke.color)]
                style.borders = []
            }
        }
        guard !path.isEmpty else { return nil }
        let bounds = path.boundingBoxOfPath
        // The geometry is in the node's own coordinates; the frame keeps its center, as rotation pivots there.
        let vector = VectorPath(path, fillRule: rule).applying(CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY))
        let center = CGPoint(x: frame.x + frame.width / 2, y: frame.y + frame.height / 2)
        let offset = CGPoint(x: bounds.midX - frame.width / 2, y: bounds.midY - frame.height / 2)
            .applying(CGAffineTransform(rotationAngle: Self.rotation(node) * .pi / 180))
        return Layer(name: name, kind: .path(vector),
                     frame: Rect(x: center.x + offset.x - bounds.width / 2, y: center.y + offset.y - bounds.height / 2,
                                 width: bounds.width, height: bounds.height), style: style)
    }

    // MARK: Styles

    private func shapeStyle(_ node: JSON) -> Style {
        var style = Style(fills: fills(node.objects("fills")))
        let weight = node.number("strokeWeight") ?? 1
        let position: Border.Position = switch node.string("strokeAlign") {
        case "INSIDE": .inside
        case "OUTSIDE": .outside
        default: .center
        }
        let cap: Border.Cap = switch node.string("strokeCap") {
        case "ROUND": .round
        case "SQUARE": .square
        default: .butt
        }
        let join: Border.Join = switch node.string("strokeJoin") {
        case "ROUND": .round
        case "BEVEL": .bevel
        default: .miter
        }
        let dashes = (node["strokeDashes"] as? [NSNumber])?.map(\.doubleValue) ?? []
        style.borders = fills(node.objects("strokes")).map { paint in
            Border(paint.gradient?.stops.first?.color ?? paint.color, width: weight, position: position, dashes: dashes, cap: cap, join: join)
        }
        return style
    }

    private func fills(_ paints: [JSON]) -> [Fill] {
        paints.filter(\.isVisible).compactMap { paint in
            let opacity = paint.number("opacity") ?? 1
            switch paint.type {
            case "SOLID":
                return color(paint.object("color")).map { Fill(Self.multiplied($0, by: opacity)) }
            case "GRADIENT_LINEAR", "GRADIENT_RADIAL", "GRADIENT_ANGULAR", "GRADIENT_DIAMOND":
                let handles = paint.objects("gradientHandlePositions").map { CGPoint(x: $0.number("x") ?? 0, y: $0.number("y") ?? 0) }
                let stops = paint.objects("gradientStops").compactMap { stop -> GradientStop? in
                    color(stop.object("color")).map { GradientStop(position: stop.number("position") ?? 0, color: Self.multiplied($0, by: opacity)) }
                }
                guard handles.count >= 2, let first = stops.first else { return nil }
                let kind: Gradient.Kind = paint.type == "GRADIENT_LINEAR" ? .linear : .radial
                return Fill(first.color, gradient: Gradient(kind: kind, from: UnitPoint(x: handles[0].x, y: handles[0].y),
                                                            to: UnitPoint(x: handles[1].x, y: handles[1].y), stops: stops))
            default:
                return nil
            }
        }
    }

    private func effects(_ effects: [JSON]) -> (shadows: [Shadow], innerShadows: [Shadow], blur: Blur?) {
        var shadows: [Shadow] = []
        var inner: [Shadow] = []
        var blur: Blur?
        for effect in effects where effect.isVisible {
            let offset = effect.object("offset")
            let shadow = Shadow(color: color(effect.object("color")) ?? Color(red: 0, green: 0, blue: 0, alpha: 64),
                                x: offset?.number("x") ?? 0, y: offset?.number("y") ?? 0,
                                blur: effect.number("radius") ?? 0, spread: effect.number("spread") ?? 0)
            switch effect.type {
            case "DROP_SHADOW": shadows.append(shadow)
            case "INNER_SHADOW": inner.append(shadow)
            case "LAYER_BLUR": blur = Blur(radius: (effect.number("radius") ?? 0) / 2)
            default: break
            }
        }
        return (shadows, inner, blur)
    }

    private func color(_ json: JSON?) -> Color? {
        guard let json, let red = json.number("r"), let green = json.number("g"), let blue = json.number("b") else { return nil }
        let byte = { (value: Double) in UInt8(max(0, min(255, (value * 255).rounded()))) }
        return Color(red: byte(red), green: byte(green), blue: byte(blue), alpha: byte(json.number("a") ?? 1))
    }

    static func multiplied(_ color: Color, by opacity: Double) -> Color {
        var color = color
        color.alpha = UInt8(max(0, min(255, (Double(color.alpha) * opacity).rounded())))
        return color
    }

    private static func blendMode(_ name: String?) -> BlendMode {
        switch name {
        case "DARKEN": .darken
        case "MULTIPLY": .multiply
        case "COLOR_BURN", "LINEAR_BURN": .colorBurn
        case "LIGHTEN": .lighten
        case "SCREEN": .screen
        case "COLOR_DODGE", "LINEAR_DODGE": .colorDodge
        case "OVERLAY": .overlay
        case "SOFT_LIGHT": .softLight
        case "HARD_LIGHT": .hardLight
        case "DIFFERENCE": .difference
        case "EXCLUSION": .exclusion
        case "HUE": .hue
        case "SATURATION": .saturation
        case "COLOR": .color
        case "LUMINOSITY": .luminosity
        default: .normal
        }
    }

    // MARK: Text

    private func text(_ node: JSON) -> TextContent {
        let characters = node.string("characters") ?? ""
        let base = node.object("style") ?? [:]
        let baseColor = fills(node.objects("fills")).first?.color ?? .black
        let overrides = (node["characterStyleOverrides"] as? [NSNumber])?.map(\.intValue) ?? []
        let table = node.object("styleOverrideTable") ?? [:]
        // Overrides are per UTF-16 unit; consecutive units with the same override form a run.
        let units = Array(characters.utf16)
        var runs: [TextRun] = []
        var start = 0
        while start < units.count {
            let key = start < overrides.count ? overrides[start] : 0
            var end = start + 1
            while end < units.count, (end < overrides.count ? overrides[end] : 0) == key { end += 1 }
            var style = base
            if key != 0, let override = table.object(String(key)) { style.merge(override) { _, new in new } }
            let color = style["fills"] == nil ? baseColor : fills(style.objects("fills")).first?.color ?? baseColor
            runs.append(TextRun(text: String(decoding: units[start..<end], as: UTF16.self), style: textStyle(style, color: color)))
            start = end
        }
        if runs.isEmpty { runs = [TextRun(text: "", style: textStyle(base, color: baseColor))] }
        let alignment: TextContent.Alignment = switch base.string("textAlignHorizontal") {
        case "CENTER": .center
        case "RIGHT": .right
        case "JUSTIFIED": .justified
        default: .left
        }
        let sizing: TextContent.Sizing = switch node.string("textAutoResize") {
        case "WIDTH_AND_HEIGHT": .autoWidth
        case "HEIGHT": .autoHeight
        default: .fixed
        }
        return TextContent(runs: runs, alignment: alignment, sizing: sizing).normalized()
    }

    private func textStyle(_ style: JSON, color: Color) -> TextStyle {
        let weight = Int(style.number("fontWeight") ?? 400)
        let italic = style.bool("italic")
        let font = style.string("fontPostScriptName").flatMap { CTFontNameIsInstalled($0) ? $0 : nil }
            ?? style.string("fontFamily").flatMap { FontFaces.face(family: $0, weight: weight, italic: italic) }
            ?? FontFaces.face(family: "Helvetica Neue", weight: weight, italic: italic)
            ?? TextStyle.defaultFont
        var result = TextStyle(fontName: font, fontSize: style.number("fontSize") ?? 16, color: color,
                               letterSpacing: style.number("letterSpacing") ?? 0)
        if style.string("lineHeightUnit") != "INTRINSIC_%", let lineHeight = style.number("lineHeightPx") { result.lineHeight = lineHeight }
        result.underline = style.string("textDecoration") == "UNDERLINE"
        return result
    }

    // MARK: Layout and export

    private func constraints(_ json: JSON?) -> Constraints {
        func pin(_ value: String?) -> Constraints.Pin {
            switch value {
            case "RIGHT", "BOTTOM": .end
            case "LEFT_RIGHT", "TOP_BOTTOM": .both
            case "CENTER": .center
            case "SCALE": .scale
            default: .start
            }
        }
        return Constraints(horizontal: pin(json?.string("horizontal")), vertical: pin(json?.string("vertical")))
    }

    private func stack(_ node: JSON) -> StackLayout? {
        guard let mode = node.string("layoutMode"), mode == "HORIZONTAL" || mode == "VERTICAL" else { return nil }
        let alignment: StackLayout.Alignment = switch node.string("counterAxisAlignItems") {
        case "CENTER": .center
        case "MAX": .end
        default: .start
        }
        return StackLayout(direction: mode == "HORIZONTAL" ? .horizontal : .vertical, spacing: node.number("itemSpacing") ?? 0,
                           padding: Insets(top: node.number("paddingTop") ?? 0, right: node.number("paddingRight") ?? 0,
                                           bottom: node.number("paddingBottom") ?? 0, left: node.number("paddingLeft") ?? 0),
                           alignment: alignment, hugsContents: node.string("primaryAxisSizingMode") != "FIXED")
    }

    private func exports(_ settings: [JSON]) -> [ExportPreset] {
        settings.compactMap { setting in
            guard let format = ExportPreset.Format(rawValue: (setting.string("format") ?? "PNG").lowercased()) else { return nil }
            let constraint = setting.object("constraint")
            let value = constraint?.number("value") ?? 1
            let size: ExportPreset.Size = switch constraint?.string("type") {
            case "WIDTH": .width(value)
            case "HEIGHT": .height(value)
            default: .scale(max(value, 0.01))
            }
            return ExportPreset(size: size, suffix: setting.string("suffix") ?? "", format: format)
        }
    }

    // MARK: Instances

    /// What an instance shows differently from its component: texts, first fill colors,
    /// visibility and swapped nested instances, keyed by the component's layer IDs.
    private func overrides(instance: JSON, component: JSON) -> [LayerID: LayerOverride] {
        var originals: [String: JSON] = [:]
        func index(_ node: JSON) {
            if let id = node.string("id") { originals[id] = node }
            for child in node.objects("children") { index(child) }
        }
        index(component)
        for nested in components.values { index(nested) }

        var result: [LayerID: LayerOverride] = [:]
        func visit(_ node: JSON) {
            guard let id = node.string("id"), let key = id.split(separator: ";").last.map(String.init), let original = originals[key] else {
                node.objects("children").forEach(visit)
                return
            }
            var override = LayerOverride()
            if node.isVisible != original.isVisible { override.isVisible = node.isVisible }
            if node.type == "TEXT", node.string("characters") != original.string("characters") { override.text = node.string("characters") }
            let color = fills(node.objects("fills")).first?.color
            if color != fills(original.objects("fills")).first?.color, let color { override.color = color }
            if node.type == "INSTANCE", let swapped = node.string("componentId"), swapped != original.string("componentId"), components[swapped] != nil {
                override.symbolID = SymbolID(swapped)
            }
            if !override.isEmpty { result[LayerID(key)] = override }
            node.objects("children").forEach(visit)
        }
        instance.objects("children").forEach(visit)
        return result
    }
}

private func CTFontNameIsInstalled(_ name: String) -> Bool {
    let font = CTFontCreateWithName(name as CFString, 12, nil)
    return (CTFontCopyPostScriptName(font) as String) == name
}
