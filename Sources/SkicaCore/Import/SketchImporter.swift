import CoreGraphics
import Foundation
import ZIPFoundation

/// Opens `.sketch` files: pages, artboards (and Sketch 2025 frames), groups, shapes, boolean
/// shape groups, text, bitmaps, symbols with overrides, shared styles, swatches, constraints
/// and export presets. Prototyping, slices and image fills are left out.
public enum SketchImporter {
    public static func document(from data: Data) throws -> Document {
        let archive: Archive
        do {
            archive = try Archive(data: data, accessMode: .read)
        } catch {
            throw ImportError.invalid("This is not a Sketch file (it is not a zip archive).")
        }
        guard let documentJSON = try? json(at: "document.json", in: archive) else {
            throw ImportError.invalid("This Sketch file has no document.json. Files from Sketch 43 or later are supported.")
        }
        var importer = Importer(archive: archive)
        return try importer.importDocument(documentJSON)
    }

    static func json(at path: String, in archive: Archive) throws -> [String: Any] {
        guard let entry = archive[path] else { throw ImportError.invalid("\(path) is missing from the Sketch file.") }
        var data = Data()
        _ = try archive.extract(entry) { data.append($0) }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ImportError.invalid("\(path) in the Sketch file is not valid JSON.")
        }
        return object
    }
}

private typealias JSON = [String: Any]

private extension Dictionary where Key == String, Value == Any {
    func string(_ key: String) -> String? { self[key] as? String }
    func number(_ key: String) -> Double? { (self[key] as? NSNumber)?.doubleValue }
    func bool(_ key: String) -> Bool { (self[key] as? NSNumber)?.boolValue ?? false }
    func object(_ key: String) -> JSON? { self[key] as? JSON }
    func objects(_ key: String) -> [JSON] { self[key] as? [JSON] ?? [] }
    var className: String { string("_class") ?? "" }
}

private struct Importer {
    let archive: Archive
    var document = Document(pages: [], layers: [:])
    private var usedIDs = Set<LayerID>()
    private var imageHashes: [String: String] = [:]

    init(archive: Archive) {
        self.archive = archive
    }

    mutating func importDocument(_ json: JSON) throws -> Document {
        importAssets(json)
        for reference in json.objects("pages") {
            guard let ref = reference.string("_ref") else { continue }
            let path = ref.hasSuffix(".json") ? ref : ref + ".json"
            let page = try SketchImporter.json(at: path, in: archive)
            importPage(page)
        }
        importForeignSymbols(json)
        if document.pages.isEmpty { document.pages = [Page(name: "Page 1")] }
        return document
    }

    // MARK: Pages and layers

    private mutating func importPage(_ json: JSON) {
        var page = Page(name: json.string("name") ?? "Page \(document.pages.count + 1)")
        for child in json.objects("layers") {
            if let id = importLayer(child, parent: nil, topLevel: true) { page.layers.append(id) }
        }
        document.pages.append(page)
    }

    /// Adds a layer and its children; returns nil for layers that are left out.
    private mutating func importLayer(_ json: JSON, parent: LayerID?, topLevel: Bool) -> LayerID? {
        let frame = rect(json.object("frame"))
        let name = json.string("name") ?? json.className
        var layer: Layer
        var children = json.objects("layers")
        switch json.className {
        case "artboard":
            layer = Layer(name: name, kind: .artboard, frame: frame, style: background(json) ?? Style(fills: [Fill(.white)]))
        case "symbolMaster":
            let symbolID = SymbolID(json.string("symbolID") ?? UUID().uuidString)
            layer = Layer(name: name, kind: .symbolMaster(symbolID), frame: frame, style: background(json) ?? Style())
        case "group" where topLevel && (json.number("groupBehavior") ?? 0) == 1:
            // Sketch 2025 frames at the top of a page are artboards.
            layer = Layer(name: name, kind: .artboard, frame: frame, style: style(json.object("style")))
        case "group":
            layer = Layer(name: name, kind: .group, frame: frame)
            if (json.number("groupBehavior") ?? 0) == 1, let fills = json.object("style").map({ style($0) })?.fills, !fills.isEmpty {
                // A nested frame's fill becomes a rectangle at the bottom of the group.
                var background = Layer(name: "Background", kind: .rectangle(cornerRadius: 0),
                                       frame: Rect(x: 0, y: 0, width: frame.width, height: frame.height), style: Style(fills: fills))
                background.id = .make()
                children.insert(["__background": background], at: 0)
            }
        case "symbolInstance":
            let instance = SymbolInstance(symbolID: SymbolID(json.string("symbolID") ?? ""), overrides: overrides(json.objects("overrideValues")))
            layer = Layer(name: name, kind: .symbolInstance(instance), frame: frame)
            children = []
        case "rectangle":
            let points = json.objects("points")
            let radius = json.number("fixedRadius").flatMap { $0 > 0 ? $0 : nil }
                ?? points.compactMap { $0.number("cornerRadius") }.max() ?? 0
            layer = Layer(name: name, kind: .rectangle(cornerRadius: min(radius, min(frame.width, frame.height) / 2)), frame: frame)
        case "oval":
            layer = Layer(name: name, kind: .oval, frame: frame)
        case "shapePath", "triangle", "star", "polygon":
            guard let path = shapePath(json, size: frame.cgRect.size) else { return nil }
            layer = Self.pathLayer(path, frame: frame, name: name, fillRule: windingRule(json))
        case "shapeGroup":
            guard let path = combinedPath(children, size: frame.cgRect.size) else { return nil }
            layer = Self.pathLayer(path, frame: frame, name: name, fillRule: windingRule(json))
            children = []
        case "text":
            layer = Layer(name: name, kind: .text(text(json)), frame: frame)
        case "bitmap":
            guard let hash = image(json.object("image")) else { return nil }
            layer = Layer(name: name, kind: .image(hash: hash), frame: frame)
        default:
            return nil
        }

        layer.id = uniqueID(json.string("do_objectID"))
        layer.parent = parent
        layer.isVisible = json["isVisible"] == nil || json.bool("isVisible")
        layer.isLocked = json.bool("isLocked")
        layer.isMask = json.bool("hasClippingMask")
        layer.rotation = -(json.number("rotation") ?? 0)
        layer.constraints = constraints(json)
        layer.exports = exports(json.object("exportOptions"))
        if let styleJSON = json.object("style") {
            let context = styleJSON.object("contextSettings")
            layer.opacity = context?.number("opacity") ?? 1
            layer.style.blendMode = Self.blendMode(context?.number("blendMode"))
            if !layer.isArtboard, layer.kind != .group, layer.symbolInstance == nil, layer.textContent == nil {
                let blend = layer.style.blendMode
                layer.style = style(styleJSON)
                layer.style.blendMode = blend
            }
        }
        if let styleID = json.string("sharedStyleID"), document.assets.sharedStyle(SharedStyleID(styleID)) != nil {
            layer.sharedStyleID = SharedStyleID(styleID)
        }
        document.layers[layer.id] = layer

        for child in children {
            if let background = child["__background"] as? Layer {
                var background = background
                background.parent = layer.id
                document.layers[background.id] = background
                document.layers[layer.id]?.children.append(background.id)
            } else if let childID = importLayer(child, parent: layer.id, topLevel: false) {
                document.layers[layer.id]?.children.append(childID)
            }
        }
        return layer.id
    }

    private mutating func uniqueID(_ raw: String?) -> LayerID {
        // Layer IDs follow Sketch's object IDs so that overrides keep pointing at their layers.
        var id = raw.map(LayerID.init) ?? .make()
        if usedIDs.contains(id) { id = .make() }
        usedIDs.insert(id)
        return id
    }

    private func background(_ json: JSON) -> Style? {
        guard json.bool("hasBackgroundColor"), let color = color(json.object("backgroundColor")) else { return nil }
        return Style(fills: [Fill(color)])
    }

    // MARK: Paths

    /// A shape's outline in its own coordinates (points are stored as fractions of the frame).
    private func shapePath(_ json: JSON, size: CGSize) -> CGPath? {
        let points = json.objects("points")
        guard points.count >= 2 else { return nil }
        func position(_ key: String, of point: JSON) -> CGPoint {
            let unit = Self.point(point.string(key))
            return CGPoint(x: unit.x * size.width, y: unit.y * size.height)
        }
        let path = CGMutablePath()
        path.move(to: position("point", of: points[0]))
        let closed = json.bool("isClosed")
        let count = closed ? points.count : points.count - 1
        for index in 0..<count {
            let start = points[index]
            let end = points[(index + 1) % points.count]
            let to = position("point", of: end)
            if start.bool("hasCurveFrom") || end.bool("hasCurveTo") {
                let c1 = start.bool("hasCurveFrom") ? position("curveFrom", of: start) : position("point", of: start)
                let c2 = end.bool("hasCurveTo") ? position("curveTo", of: end) : to
                path.addCurve(to: to, control1: c1, control2: c2)
            } else {
                path.addLine(to: to)
            }
        }
        if closed { path.closeSubpath() }
        var flip = CGAffineTransform.identity
        if json.bool("isFlippedHorizontal") { flip = flip.translatedBy(x: size.width, y: 0).scaledBy(x: -1, y: 1) }
        if json.bool("isFlippedVertical") { flip = flip.translatedBy(x: 0, y: size.height).scaledBy(x: 1, y: -1) }
        return path.copy(using: &flip)
    }

    /// The children of a shape group joined by their boolean operations, in the group's coordinates.
    private func combinedPath(_ children: [JSON], size: CGSize) -> CGPath? {
        var result: CGPath?
        for child in children where child["isVisible"] == nil || child.bool("isVisible") {
            let frame = rect(child.object("frame")).cgRect
            let local: CGPath?
            switch child.className {
            case "rectangle":
                let radius = child.number("fixedRadius") ?? child.objects("points").compactMap { $0.number("cornerRadius") }.max() ?? 0
                let corner = min(radius, min(frame.width, frame.height) / 2)
                local = CGPath(roundedRect: CGRect(origin: .zero, size: frame.size), cornerWidth: corner, cornerHeight: corner, transform: nil)
            case "oval":
                local = CGPath(ellipseIn: CGRect(origin: .zero, size: frame.size), transform: nil)
            case "shapeGroup":
                local = combinedPath(child.objects("layers"), size: frame.size)
            default:
                local = shapePath(child, size: frame.size)
            }
            guard let local else { continue }
            var placement = CGAffineTransform(translationX: frame.midX, y: frame.midY)
                .rotated(by: -(child.number("rotation") ?? 0) * .pi / 180)
                .translatedBy(x: -frame.width / 2, y: -frame.height / 2)
            guard let placed = local.copy(using: &placement) else { continue }
            guard let current = result else {
                result = placed
                continue
            }
            switch child.number("booleanOperation") ?? -1 {
            case 0: result = current.union(placed)
            case 1: result = current.subtracting(placed)
            case 2: result = current.intersection(placed)
            case 3: result = current.symmetricDifference(placed)
            default:
                let joined = CGMutablePath()
                joined.addPath(current)
                joined.addPath(placed)
                result = joined
            }
        }
        return result
    }

    /// A path layer at `frame`, moved and resized to the path's actual bounds.
    static func pathLayer(_ path: CGPath, frame: Rect, name: String, fillRule: VectorPath.FillRule) -> Layer {
        let bounds = path.isEmpty ? .zero : path.boundingBoxOfPath
        let vector = VectorPath(path, fillRule: fillRule).applying(CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY))
        return Layer(name: name, kind: .path(vector),
                     frame: Rect(x: frame.x + bounds.minX, y: frame.y + bounds.minY, width: bounds.width, height: bounds.height))
    }

    private func windingRule(_ json: JSON) -> VectorPath.FillRule {
        let rule = json.number("windingRule") ?? json.object("style")?.number("windingRule") ?? 1
        return rule == 1 ? .evenOdd : .nonZero
    }

    // MARK: Text

    private func text(_ json: JSON) -> TextContent {
        let attributed = json.object("attributedString")
        let string = attributed?.string("string") ?? ""
        let defaults = json.object("style")?.object("textStyle")?.object("encodedAttributes") ?? [:]
        let utf16 = Array(string.utf16)
        var runs: [TextRun] = []
        var alignment = Self.alignment(defaults.object("paragraphStyle"))
        for (index, run) in (attributed?.objects("attributes") ?? []).enumerated() {
            let attributes = run.object("attributes") ?? defaults
            let location = Int(run.number("location") ?? 0)
            let length = Int(run.number("length") ?? 0)
            guard location >= 0, length > 0, location + length <= utf16.count else { continue }
            let text = String(decoding: utf16[location..<(location + length)], as: UTF16.self)
            runs.append(TextRun(text: text, style: textStyle(attributes)))
            if index == 0 { alignment = Self.alignment(attributes.object("paragraphStyle")) }
        }
        if runs.isEmpty { runs = [TextRun(text: string, style: textStyle(defaults))] }
        let sizing: TextContent.Sizing = switch json.number("textBehaviour") ?? 0 {
        case 1: .autoHeight
        case 2: .fixed
        default: .autoWidth
        }
        return TextContent(runs: runs, alignment: alignment, sizing: sizing).normalized()
    }

    private func textStyle(_ attributes: JSON) -> TextStyle {
        let font = attributes.object("MSAttributedStringFontAttribute")?.object("attributes")
        var style = TextStyle(fontName: font?.string("name") ?? TextStyle.defaultFont, fontSize: font?.number("size") ?? 16,
                              color: color(attributes.object("MSAttributedStringColorAttribute")) ?? .black,
                              letterSpacing: attributes.number("kerning") ?? 0)
        if let lineHeight = attributes.object("paragraphStyle")?.number("maximumLineHeight"), lineHeight > 0 { style.lineHeight = lineHeight }
        style.underline = (attributes.number("underlineStyle") ?? 0) != 0
        return style
    }

    private static func alignment(_ paragraph: JSON?) -> TextContent.Alignment {
        switch paragraph?.number("alignment") ?? 0 {
        case 1: .right
        case 2: .center
        case 3: .justified
        default: .left
        }
    }

    // MARK: Styles

    private func style(_ json: JSON?) -> Style {
        guard let json else { return Style() }
        var style = Style()
        style.fills = json.objects("fills").compactMap(fill)
        let options = json.object("borderOptions")
        style.borders = json.objects("borders").compactMap { border -> Border? in
            guard let paint = fill(border) else { return nil }
            let position: Border.Position = switch border.number("position") ?? 0 {
            case 1: .inside
            case 2: .outside
            default: .center
            }
            let cap: Border.Cap = switch options?.number("lineCapStyle") ?? 0 {
            case 1: .round
            case 2: .square
            default: .butt
            }
            let join: Border.Join = switch options?.number("lineJoinStyle") ?? 0 {
            case 1: .round
            case 2: .bevel
            default: .miter
            }
            let dashes = (options?["dashPattern"] as? [NSNumber])?.map(\.doubleValue) ?? []
            return Border(paint.gradient?.stops.first?.color ?? paint.color, width: border.number("thickness") ?? 1, position: position,
                          dashes: dashes, cap: cap, join: join, isEnabled: paint.isEnabled)
        }
        style.shadows = json.objects("shadows").map(shadow)
        style.innerShadows = json.objects("innerShadows").map(shadow)
        let blurs = json.objects("blurs") + (json.object("blur").map { [$0] } ?? [])
        if let blur = blurs.first(where: { ($0.number("type") ?? 0) == 0 && $0.bool("isEnabled") }) {
            style.blur = Blur(radius: blur.number("radius") ?? 4)
        }
        style.blendMode = Self.blendMode(json.object("contextSettings")?.number("blendMode"))
        return style
    }

    private func fill(_ json: JSON) -> Fill? {
        let opacity = json.object("contextSettings")?.number("opacity") ?? 1
        let enabled = json["isEnabled"] == nil || json.bool("isEnabled")
        switch json.number("fillType") ?? 0 {
        case 0:
            guard let color = color(json.object("color")) else { return nil }
            return Fill(Self.multiplied(color, by: opacity), isEnabled: enabled)
        case 1:
            guard let gradient = json.object("gradient") else { return nil }
            let stops = gradient.objects("stops").compactMap { stop -> GradientStop? in
                guard let color = color(stop.object("color")) else { return nil }
                return GradientStop(position: stop.number("position") ?? 0, color: Self.multiplied(color, by: opacity))
            }
            guard !stops.isEmpty else { return nil }
            let from = Self.point(gradient.string("from"))
            let to = Self.point(gradient.string("to"))
            let kind: Gradient.Kind = gradient.number("gradientType") == 1 ? .radial : .linear
            return Fill(stops[0].color, gradient: Gradient(kind: kind, from: UnitPoint(x: from.x, y: from.y), to: UnitPoint(x: to.x, y: to.y), stops: stops),
                        isEnabled: enabled)
        default:
            return nil
        }
    }

    private func shadow(_ json: JSON) -> Shadow {
        Shadow(color: color(json.object("color")) ?? Color(red: 0, green: 0, blue: 0, alpha: 128), x: json.number("offsetX") ?? 0,
               y: json.number("offsetY") ?? 0, blur: json.number("blurRadius") ?? 0, spread: json.number("spread") ?? 0,
               isEnabled: json["isEnabled"] == nil || json.bool("isEnabled"))
    }

    private func color(_ json: JSON?) -> Color? {
        guard let json, let red = json.number("red"), let green = json.number("green"), let blue = json.number("blue") else { return nil }
        let byte = { (value: Double) in UInt8(max(0, min(255, (value * 255).rounded()))) }
        return Color(red: byte(red), green: byte(green), blue: byte(blue), alpha: byte(json.number("alpha") ?? 1))
    }

    static func multiplied(_ color: Color, by opacity: Double) -> Color {
        var color = color
        color.alpha = UInt8(max(0, min(255, (Double(color.alpha) * opacity).rounded())))
        return color
    }

    private static func blendMode(_ value: Double?) -> BlendMode {
        let modes: [BlendMode] = [.normal, .darken, .multiply, .colorBurn, .lighten, .screen, .colorDodge, .overlay, .softLight,
                                  .hardLight, .difference, .exclusion, .hue, .saturation, .color, .luminosity]
        let index = Int(value ?? 0)
        return modes.indices.contains(index) ? modes[index] : .normal
    }

    // MARK: Constraints and export

    /// Sketch 2025 pins (bit 1 left/top, bit 2 right/bottom, sizing 3 = relative), or the older
    /// `resizingConstraint` mask where a cleared bit fixes that edge or size.
    private func constraints(_ json: JSON) -> Constraints {
        if let horizontalPins = json.number("horizontalPins"), let verticalPins = json.number("verticalPins") {
            func pin(_ pins: Double, sizing: Double?) -> Constraints.Pin {
                switch Int(pins) {
                case 3: return .both
                case 1: return .start
                case 2: return .end
                default: return sizing == 3 ? .scale : .center
                }
            }
            return Constraints(horizontal: pin(horizontalPins, sizing: json.number("horizontalSizing")),
                               vertical: pin(verticalPins, sizing: json.number("verticalSizing")))
        }
        let mask = Int(json.number("resizingConstraint") ?? 63)
        func pin(start: Int, end: Int, size: Int) -> Constraints.Pin {
            let fixedStart = mask & start == 0
            let fixedEnd = mask & end == 0
            let fixedSize = mask & size == 0
            switch (fixedStart, fixedEnd) {
            case (true, true): return .both
            case (true, false): return .start
            case (false, true): return .end
            default: return fixedSize ? .center : .scale
            }
        }
        return Constraints(horizontal: pin(start: 4, end: 1, size: 2), vertical: pin(start: 32, end: 8, size: 16))
    }

    private func exports(_ json: JSON?) -> [ExportPreset] {
        (json?.objects("exportFormats") ?? []).compactMap { format in
            guard let fileFormat = ExportPreset.Format(rawValue: format.string("fileFormat") == "jpeg" ? "jpg" : format.string("fileFormat") ?? "png") else { return nil }
            let absolute = format.number("absoluteSize") ?? 0
            let size: ExportPreset.Size = switch format.number("visibleScaleType") ?? 0 {
            case 1 where absolute > 0: .width(absolute)
            case 2 where absolute > 0: .height(absolute)
            default: .scale(max(format.number("scale") ?? 1, 0.01))
            }
            return ExportPreset(size: size, suffix: format.string("name") ?? "", format: fileFormat)
        }
    }

    // MARK: Symbols, images and assets

    /// Overrides keyed by the innermost layer of their path (`outer/inner_stringValue`).
    private mutating func overrides(_ values: [JSON]) -> [LayerID: LayerOverride] {
        var result: [LayerID: LayerOverride] = [:]
        for value in values {
            guard let name = value.string("overrideName"), let separator = name.lastIndex(of: "_") else { continue }
            let path = name[..<separator]
            let property = name[name.index(after: separator)...]
            guard let target = path.split(separator: "/").last.map({ LayerID(String($0)) }) else { continue }
            var override = result[target] ?? LayerOverride()
            switch property {
            case "stringValue":
                override.text = value.string("value")
            case "symbolID":
                if let symbol = value.string("value") {
                    if symbol.isEmpty { override.isVisible = false } else { override.symbolID = SymbolID(symbol) }
                }
            case "fillColor":
                override.color = color(value.object("value"))
            case "image":
                override.imageHash = (value.object("value")).flatMap { imageHash($0) }
            default:
                continue
            }
            if !override.isEmpty { result[target] = override }
        }
        return result
    }

    private mutating func image(_ reference: JSON?) -> String? {
        reference.flatMap { imageHash($0) }
    }

    /// Reads an image from the archive into the document once (Sketch refs may omit the extension).
    private mutating func imageHash(_ reference: JSON) -> String? {
        guard let ref = reference.string("_ref") else { return nil }
        if let hash = imageHashes[ref] { return hash }
        let candidates = [ref, ref + ".png", ref + ".jpg", ref + ".pdf"]
        let archive = archive
        guard let entry = candidates.lazy.compactMap({ archive[$0] }).first else { return nil }
        var data = Data()
        guard (try? archive.extract(entry) { data.append($0) }) != nil, ImageData.naturalSize(of: data) != nil else { return nil }
        let hash = ImageData.hash(of: data)
        document.images[hash] = data
        imageHashes[ref] = hash
        return hash
    }

    private mutating func importAssets(_ json: JSON) {
        let styles = json.object("layerStyles")?.objects("objects") ?? []
        let textStyles = json.object("layerTextStyles")?.objects("objects") ?? []
        let foreignStyles = json.objects("foreignLayerStyles").compactMap { $0.object("localSharedStyle") }
        let foreignTextStyles = json.objects("foreignTextStyles").compactMap { $0.object("localSharedStyle") }
        for shared in styles + foreignStyles {
            guard let id = shared.string("do_objectID"), let value = shared.object("value") else { continue }
            document.assets.sharedStyles.append(SharedStyle(id: SharedStyleID(id), name: shared.string("name") ?? "Style", content: .layer(style(value))))
        }
        for shared in textStyles + foreignTextStyles {
            guard let id = shared.string("do_objectID"), let attributes = shared.object("value")?.object("textStyle")?.object("encodedAttributes") else { continue }
            document.assets.sharedStyles.append(SharedStyle(id: SharedStyleID(id), name: shared.string("name") ?? "Text Style",
                                                            content: .text(textStyle(attributes), alignment: Self.alignment(attributes.object("paragraphStyle")))))
        }
        let swatches = (json.object("sharedSwatches")?.objects("objects") ?? []) + json.objects("foreignSwatches").compactMap { $0.object("localSharedSwatch") }
        for swatch in swatches {
            guard let color = color(swatch.object("value")) else { continue }
            document.assets.swatches.append(Swatch(name: swatch.string("name") ?? color.hex, color: color))
        }
        for asset in json.object("assets")?.objects("colorAssets") ?? [] {
            guard let color = color(asset.object("color")), !document.assets.swatches.contains(where: { $0.color == color }) else { continue }
            document.assets.swatches.append(Swatch(name: asset.string("name").flatMap { $0.isEmpty ? nil : $0 } ?? color.hex, color: color))
        }
    }

    /// Symbols from libraries arrive as copies of their masters; they go on the Symbols page.
    private mutating func importForeignSymbols(_ json: JSON) {
        let masters = json.objects("foreignSymbols").compactMap { $0.object("symbolMaster") }
            .filter { master in master.string("symbolID").map { document.master(of: SymbolID($0)) == nil } ?? false }
        guard !masters.isEmpty else { return }
        let pageIndex = document.pages.firstIndex { $0.name == "Symbols" } ?? {
            document.pages.append(Page(name: "Symbols"))
            return document.pages.count - 1
        }()
        var x = document.contentBounds(of: document.pages[pageIndex]).map { $0.maxX + 100 } ?? 0
        for master in masters {
            guard let id = importLayer(master, parent: nil, topLevel: true) else { continue }
            document.layers[id]?.frame.x = x
            document.layers[id]?.frame.y = 0
            x += (document.layers[id]?.frame.width ?? 0) + 100
            document.pages[pageIndex].layers.append(id)
        }
    }

    // MARK: Values

    private func rect(_ json: JSON?) -> Rect {
        Rect(x: json?.number("x") ?? 0, y: json?.number("y") ?? 0, width: json?.number("width") ?? 0, height: json?.number("height") ?? 0)
    }

    /// `"{0.5, 1}"` as a point.
    static func point(_ text: String?) -> CGPoint {
        let values = NumberScanner.numbers(in: (text ?? "").replacingOccurrences(of: "{", with: " ").replacingOccurrences(of: "}", with: " "))
        return values.count >= 2 ? CGPoint(x: values[0], y: values[1]) : .zero
    }
}
