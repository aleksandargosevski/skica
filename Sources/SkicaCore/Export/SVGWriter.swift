import CoreGraphics
import Foundation

/// Writes layers as clean SVG: real `rect`, `ellipse`, `line` and `path` elements, gradients,
/// borders inside or outside (with clip paths and masks), shadows and blur as filters, and text
/// as `text` elements broken into the same lines as on the canvas.
public struct SVGWriter {
    private var document: Document
    private var defs: [String] = []
    private var nextID = 0

    private init(document: Document) {
        self.document = document
    }

    /// An SVG file of one layer (an artboard, a shape, a group…), sized to its export bounds.
    /// A hidden layer is shown in its own export.
    public static func svg(of id: LayerID, in document: Document) -> String? {
        guard document.layers[id] != nil, let bounds = document.exportBounds(of: id) else { return nil }
        var writer = SVGWriter(document: document)
        writer.document.layers[id]?.isVisible = true
        let body = writer.write(id)
        let space = document.parentSpace(of: id)
        let content = space.isIdentity ? body : "<g transform=\"\(matrix(space))\">\(body)</g>"
        let defs = writer.defs.isEmpty ? "" : "<defs>\(writer.defs.joined())</defs>"
        return """
        <svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" \
        width="\(number(bounds.width))" height="\(number(bounds.height))" \
        viewBox="\(number(bounds.minX)) \(number(bounds.minY)) \(number(bounds.width)) \(number(bounds.height))">\
        \(defs)\(content)</svg>

        """
    }

    // MARK: Layers

    /// One layer in its parent's coordinates, wrapped for opacity, blend mode, effects and rotation.
    /// `scope` carries the overrides of the symbol instances being drawn.
    private mutating func write(_ id: LayerID, scope: SymbolScope = .root) -> String {
        guard let stored = document.layers[id] else { return "" }
        let layer = scope.resolve(stored)
        guard layer.isVisible else { return "" }
        let frame = layer.frame.cgRect
        var content: String
        switch layer.kind {
        case .symbolInstance(let instance):
            content = writeInstance(instance, frame: frame, scope: scope)
        case .artboard, .symbolMaster:
            let clip = makeID("clip")
            defs.append("<clipPath id=\"\(clip)\"><rect width=\"\(Self.number(frame.width))\" height=\"\(Self.number(frame.height))\"/></clipPath>")
            content = fills(of: layer, geometry: geometry(of: layer))
                + "<g transform=\"translate(\(Self.number(frame.minX)) \(Self.number(frame.minY)))\" clip-path=\"url(#\(clip))\">"
                + writeSiblings(layer.children, scope: scope) + "</g>"
        case .group:
            // A group resized by an instance's layout scales its contents.
            let original = stored.frame
            let scaled = original.width > 0 && original.height > 0 && (original.width != frame.width || original.height != frame.height)
            let scale = scaled ? " scale(\(Self.number(frame.width / original.width)) \(Self.number(frame.height / original.height)))" : ""
            content = "<g transform=\"translate(\(Self.number(frame.minX)) \(Self.number(frame.minY)))\(scale)\">"
                + writeSiblings(layer.children, scope: scope) + "</g>"
        case .text(let content_):
            content = text(content_, in: frame)
        case .image(let hash):
            content = croppedImage(hash, of: layer) + borders(of: layer, geometry: geometry(of: layer))
        case .line:
            content = borders(of: layer, geometry: geometry(of: layer))
        case .rectangle, .oval, .polygon, .star, .path:
            let shape = geometry(of: layer)
            content = fills(of: layer, geometry: shape) + borders(of: layer, geometry: shape)
        }

        var attributes: [String] = []
        if layer.rotation != 0 {
            attributes.append("transform=\"rotate(\(Self.number(layer.rotation)) \(Self.number(frame.midX)) \(Self.number(frame.midY)))\"")
        }
        if layer.opacity < 1 { attributes.append("opacity=\"\(Self.number(layer.opacity))\"") }
        if layer.style.blendMode != .normal { attributes.append("style=\"mix-blend-mode:\(layer.style.blendMode.css)\"") }
        if let filter = filter(for: layer) { attributes.append("filter=\"url(#\(filter))\"") }
        let name = " data-name=\"\(Self.escape(layer.name))\""
        return attributes.isEmpty && !layer.isContainer
            ? content
            : "<g\(name) \(attributes.joined(separator: " "))>\(content)</g>".replacingOccurrences(of: " >", with: ">")
    }

    /// A symbol's contents scaled into the instance's frame, with its overrides.
    private mutating func writeInstance(_ instance: SymbolInstance, frame: CGRect, scope: SymbolScope) -> String {
        guard let masterID = document.master(of: instance.symbolID), let master = document.layers[masterID],
              let inner = scope.entering(instance, master: master, size: CGSizeValue(width: frame.width, height: frame.height), in: document)
        else { return "" }
        let n = Self.number
        var atOrigin = master
        atOrigin.frame = Rect(x: 0, y: 0, width: frame.width, height: frame.height)
        let clip = makeID("clip")
        defs.append("<clipPath id=\"\(clip)\"><rect width=\"\(n(frame.width))\" height=\"\(n(frame.height))\"/></clipPath>")
        return "<g transform=\"translate(\(n(frame.minX)) \(n(frame.minY)))\" clip-path=\"url(#\(clip))\">"
            + fills(of: atOrigin, geometry: geometry(of: atOrigin)) + writeSiblings(master.children, scope: inner) + "</g>"
    }

    /// Siblings bottom to top; a mask clips everything after it, as on the canvas.
    private mutating func writeSiblings(_ ids: [LayerID], scope: SymbolScope = .root) -> String {
        var output = ""
        var openMasks = 0
        for id in ids {
            output += write(id, scope: scope)
            guard let layer = document.layers[id], layer.isMask, layer.isVisible, let shape = MaskShape.path(of: layer) else { continue }
            let clip = makeID("mask")
            let rule = layer.vectorPath?.fillRule == .evenOdd ? " clip-rule=\"evenodd\"" : ""
            defs.append("<clipPath id=\"\(clip)\"><path\(rule) d=\"\(Self.pathData(shape))\"/></clipPath>")
            output += "<g clip-path=\"url(#\(clip))\">"
            openMasks += 1
        }
        return output + String(repeating: "</g>", count: openMasks)
    }

    /// The element for a shape's outline, without paint attributes: `<rect x=… y=…`.
    private func geometry(of layer: Layer) -> String {
        let frame = layer.frame.cgRect
        let n = Self.number
        switch layer.kind {
        case .artboard, .symbolMaster, .symbolInstance, .group, .text, .image:
            return "<rect x=\"\(n(frame.minX))\" y=\"\(n(frame.minY))\" width=\"\(n(frame.width))\" height=\"\(n(frame.height))\""
        case .rectangle(let radius):
            let r = min(max(radius, 0), min(frame.width, frame.height) / 2)
            let corners = r > 0 ? " rx=\"\(n(r))\"" : ""
            return "<rect x=\"\(n(frame.minX))\" y=\"\(n(frame.minY))\" width=\"\(n(frame.width))\" height=\"\(n(frame.height))\"\(corners)"
        case .oval:
            return "<ellipse cx=\"\(n(frame.midX))\" cy=\"\(n(frame.midY))\" rx=\"\(n(frame.width / 2))\" ry=\"\(n(frame.height / 2))\""
        case .line(let from, let to):
            let start = ShapePath.point(from, in: frame)
            let end = ShapePath.point(to, in: frame)
            return "<line x1=\"\(n(start.x))\" y1=\"\(n(start.y))\" x2=\"\(n(end.x))\" y2=\"\(n(end.y))\""
        case .polygon, .star, .path:
            let rule = layer.vectorPath?.fillRule == .evenOdd ? " fill-rule=\"evenodd\" clip-rule=\"evenodd\"" : ""
            return "<path\(rule) d=\"\(ShapePath.path(for: layer).map(Self.pathData) ?? "")\""
        }
    }

    // MARK: Paint

    private mutating func fills(of layer: Layer, geometry: String) -> String {
        layer.style.fills.filter(\.isEnabled).map { fill in
            guard let gradient = fill.gradient, !gradient.stops.isEmpty else {
                return geometry + " fill=\"\(Self.hex(fill.color))\"\(Self.opacity("fill-opacity", fill.color))/>"
            }
            return geometry + " fill=\"url(#\(self.gradient(gradient, frame: layer.frame.cgRect)))\"/>"
        }.joined()
    }

    private mutating func borders(of layer: Layer, geometry: String) -> String {
        let isOpen = ShapePath.isOpen(layer.kind)
        return layer.style.borders.filter { $0.isEnabled && $0.width > 0 }.map { border in
            let position = isOpen ? .center : border.position
            var attributes = " fill=\"none\" stroke=\"\(Self.hex(border.color))\"\(Self.opacity("stroke-opacity", border.color))"
            attributes += " stroke-width=\"\(Self.number(position == .center ? border.width : border.width * 2))\""
            if border.cap != .butt { attributes += " stroke-linecap=\"\(border.cap.rawValue)\"" }
            if border.join != .miter { attributes += " stroke-linejoin=\"\(border.join.rawValue)\"" }
            let dashes = border.dashes.filter { $0 > 0 }
            if !dashes.isEmpty { attributes += " stroke-dasharray=\"\(dashes.map(Self.number).joined(separator: " "))\"" }
            switch position {
            case .center:
                break
            case .inside:
                let clip = makeID("inside")
                defs.append("<clipPath id=\"\(clip)\">\(geometry)/></clipPath>")
                attributes += " clip-path=\"url(#\(clip))\""
            case .outside:
                let mask = makeID("outside")
                let area = layer.frame.cgRect.insetBy(dx: -border.width * 2 - 1, dy: -border.width * 2 - 1)
                let box = "x=\"\(Self.number(area.minX))\" y=\"\(Self.number(area.minY))\" width=\"\(Self.number(area.width))\" height=\"\(Self.number(area.height))\""
                let visible = "<rect \(box) fill=\"white\"/>"
                let hidden = geometry + " fill=\"black\"/>"
                defs.append("<mask id=\"\(mask)\" maskUnits=\"userSpaceOnUse\" \(box)>\(visible)\(hidden)</mask>")
                attributes += " mask=\"url(#\(mask))\""
            }
            return geometry + attributes + "/>"
        }.joined()
    }

    /// A gradient in page units, matching the canvas: linear between two points of the frame,
    /// radial as a circle around the start point.
    private mutating func gradient(_ gradient: Gradient, frame: CGRect) -> String {
        let id = makeID("gradient")
        let n = Self.number
        let start = ShapePath.point(gradient.from, in: frame)
        let end = ShapePath.point(gradient.to, in: frame)
        let stops = gradient.stops.sorted { $0.position < $1.position }.map { stop in
            "<stop offset=\"\(n(stop.position))\" stop-color=\"\(Self.hex(stop.color))\"\(Self.opacity("stop-opacity", stop.color))/>"
        }.joined()
        switch gradient.kind {
        case .linear:
            defs.append("<linearGradient id=\"\(id)\" gradientUnits=\"userSpaceOnUse\" x1=\"\(n(start.x))\" y1=\"\(n(start.y))\" x2=\"\(n(end.x))\" y2=\"\(n(end.y))\">\(stops)</linearGradient>")
        case .radial:
            let radius = hypot(end.x - start.x, end.y - start.y)
            defs.append("<radialGradient id=\"\(id)\" gradientUnits=\"userSpaceOnUse\" cx=\"\(n(start.x))\" cy=\"\(n(start.y))\" r=\"\(n(radius))\">\(stops)</radialGradient>")
        }
        return id
    }

    /// Drop shadows, inner shadows and blur as one filter.
    private mutating func filter(for layer: Layer) -> String? {
        let style = layer.style
        let shadows = style.shadows.filter(\.isEnabled)
        let innerShadows = style.innerShadows.filter(\.isEnabled)
        let blur = style.blur.flatMap { $0.isEnabled && $0.radius > 0 ? $0.radius : nil }
        guard !shadows.isEmpty || !innerShadows.isEmpty || blur != nil else { return nil }

        let id = makeID("effects")
        let n = Self.number
        let region = layer.frame.cgRect.insetBy(dx: -style.paintOutset - 4, dy: -style.paintOutset - 4)
        var primitives = ""
        var below: [String] = []
        var above: [String] = []
        for (index, shadow) in shadows.enumerated() {
            let result = "drop\(index)"
            let spread = shadow.spread > 0 ? "<feMorphology in=\"SourceAlpha\" operator=\"dilate\" radius=\"\(n(shadow.spread))\" result=\"\(result)s\"/>" : ""
            primitives += spread
                + "<feOffset in=\"\(shadow.spread > 0 ? "\(result)s" : "SourceAlpha")\" dx=\"\(n(shadow.x))\" dy=\"\(n(shadow.y))\" result=\"\(result)o\"/>"
                + "<feGaussianBlur in=\"\(result)o\" stdDeviation=\"\(n(shadow.blur / 2))\" result=\"\(result)b\"/>"
                + "<feFlood flood-color=\"\(Self.hex(shadow.color))\" flood-opacity=\"\(n(Double(shadow.color.alpha) / 255))\"/>"
                + "<feComposite in2=\"\(result)b\" operator=\"in\" result=\"\(result)\"/>"
            below.append(result)
        }
        for (index, shadow) in innerShadows.enumerated() {
            let result = "inner\(index)"
            primitives += "<feOffset in=\"SourceAlpha\" dx=\"\(n(shadow.x))\" dy=\"\(n(shadow.y))\" result=\"\(result)o\"/>"
                + "<feGaussianBlur in=\"\(result)o\" stdDeviation=\"\(n(shadow.blur / 2))\" result=\"\(result)b\"/>"
                + "<feComposite in=\"SourceAlpha\" in2=\"\(result)b\" operator=\"arithmetic\" k2=\"1\" k3=\"-1\" result=\"\(result)e\"/>"
                + "<feFlood flood-color=\"\(Self.hex(shadow.color))\" flood-opacity=\"\(n(Double(shadow.color.alpha) / 255))\"/>"
                + "<feComposite in2=\"\(result)e\" operator=\"in\" result=\"\(result)\"/>"
            above.append(result)
        }
        let merged = (below + ["SourceGraphic"] + above).map { "<feMergeNode in=\"\($0)\"/>" }.joined()
        primitives += "<feMerge result=\"merged\">\(merged)</feMerge>"
        if let blur {
            primitives += "<feGaussianBlur in=\"merged\" stdDeviation=\"\(n(blur / 2))\"/>"
        }
        defs.append("<filter id=\"\(id)\" filterUnits=\"userSpaceOnUse\" x=\"\(n(region.minX))\" y=\"\(n(region.minY))\" width=\"\(n(region.width))\" height=\"\(n(region.height))\" color-interpolation-filters=\"sRGB\">\(primitives)</filter>")
        return id
    }

    // MARK: Text and images

    private func text(_ content: TextContent, in frame: CGRect) -> String {
        let n = Self.number
        let lines = TextLayout.lines(of: content, in: frame)
        let pieces = lines.flatMap { line in
            line.pieces.map { piece -> String in
                let style = piece.style
                var attributes = "x=\"\(n(piece.x))\" y=\"\(n(line.baseline.y))\""
                attributes += " font-family=\"\(Self.escape(piece.font.family)), sans-serif\" font-size=\"\(n(style.fontSize))\""
                if piece.font.weight != 400 { attributes += " font-weight=\"\(piece.font.weight)\"" }
                if piece.font.isItalic { attributes += " font-style=\"italic\"" }
                attributes += " fill=\"\(Self.hex(style.color))\"\(Self.opacity("fill-opacity", style.color))"
                if style.letterSpacing != 0 { attributes += " letter-spacing=\"\(n(style.letterSpacing))\"" }
                if style.underline { attributes += " text-decoration=\"underline\"" }
                return "<text \(attributes) xml:space=\"preserve\">\(Self.escape(piece.text))</text>"
            }
        }
        return "<g>\(pieces.joined())</g>"
    }

    /// The image at its place under the crop, clipped to the frame when cropped.
    private mutating func croppedImage(_ hash: String, of layer: Layer) -> String {
        let frame = layer.frame.cgRect
        guard layer.imageCrop != nil else { return image(hash, in: frame) }
        let n = Self.number
        let clip = makeID("clip")
        defs.append("<clipPath id=\"\(clip)\"><rect x=\"\(n(frame.minX))\" y=\"\(n(frame.minY))\" width=\"\(n(frame.width))\" height=\"\(n(frame.height))\"/></clipPath>")
        return "<g clip-path=\"url(#\(clip))\">" + image(hash, in: layer.imageRectInParent) + "</g>"
    }

    private func image(_ hash: String, in frame: CGRect) -> String {
        let n = Self.number
        guard let data = document.images[hash] else { return "" }
        let mime = switch ImageData.fileExtension(of: data) {
        case "jpg": "image/jpeg"
        case "gif": "image/gif"
        case "webp": "image/webp"
        case "heic": "image/heic"
        case "tiff": "image/tiff"
        default: "image/png"
        }
        return "<image x=\"\(n(frame.minX))\" y=\"\(n(frame.minY))\" width=\"\(n(frame.width))\" height=\"\(n(frame.height))\" preserveAspectRatio=\"none\" href=\"data:\(mime);base64,\(data.base64EncodedString())\"/>"
    }

    // MARK: Formatting

    private mutating func makeID(_ prefix: String) -> String {
        nextID += 1
        return "\(prefix)\(nextID)"
    }

    /// Up to three decimals, without trailing zeros: `12`, `12.5`, `0.333`.
    static func number(_ value: Double) -> String {
        let rounded = (value * 1000).rounded() / 1000
        if rounded == rounded.rounded(), abs(rounded) < 1e15 { return String(Int(rounded)) }
        var text = String(format: "%.3f", rounded)
        while text.hasSuffix("0") { text.removeLast() }
        return text
    }

    private static func hex(_ color: Color) -> String {
        String(Color(red: color.red, green: color.green, blue: color.blue).hex)
    }

    private static func opacity(_ attribute: String, _ color: Color) -> String {
        color.alpha == 255 ? "" : " \(attribute)=\"\(number(Double(color.alpha) / 255))\""
    }

    private static func matrix(_ t: CGAffineTransform) -> String {
        "matrix(\([t.a, t.b, t.c, t.d, t.tx, t.ty].map(number).joined(separator: " ")))"
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// SVG path data for a Core Graphics path.
    static func pathData(_ path: CGPath) -> String {
        var parts: [String] = []
        path.applyWithBlock { element in
            let points = element.pointee.points
            let p = { (index: Int) in "\(number(points[index].x)) \(number(points[index].y))" }
            switch element.pointee.type {
            case .moveToPoint: parts.append("M\(p(0))")
            case .addLineToPoint: parts.append("L\(p(0))")
            case .addQuadCurveToPoint: parts.append("Q\(p(0)) \(p(1))")
            case .addCurveToPoint: parts.append("C\(p(0)) \(p(1)) \(p(2))")
            case .closeSubpath: parts.append("Z")
            @unknown default: break
            }
        }
        return parts.joined(separator: " ")
    }
}

extension BlendMode {
    /// The CSS `mix-blend-mode` keyword.
    var css: String {
        switch self {
        case .normal: "normal"
        case .darken: "darken"
        case .multiply: "multiply"
        case .colorBurn: "color-burn"
        case .lighten: "lighten"
        case .screen: "screen"
        case .colorDodge: "color-dodge"
        case .overlay: "overlay"
        case .softLight: "soft-light"
        case .hardLight: "hard-light"
        case .difference: "difference"
        case .exclusion: "exclusion"
        case .hue: "hue"
        case .saturation: "saturation"
        case .color: "color"
        case .luminosity: "luminosity"
        }
    }
}
