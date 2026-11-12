import CoreGraphics
import CoreImage
import SkicaCore

public struct RenderOptions: Sendable {
    /// A soft shadow around artboards, as on the editing canvas; off for exports.
    public var showsArtboardShadows: Bool
    /// A layer drawn by an editor instead (e.g. text being edited), skipped here.
    public var hiddenLayer: LayerID?
    /// An image being cropped: the parts outside its crop show faintly.
    public var revealedCrop: LayerID?

    public init(showsArtboardShadows: Bool = false, hiddenLayer: LayerID? = nil, revealedCrop: LayerID? = nil) {
        self.showsArtboardShadows = showsArtboardShadows
        self.hiddenLayer = hiddenLayer
        self.revealedCrop = revealedCrop
    }
}

/// Draws a page into any CGContext whose coordinates are canvas points with y pointing down.
/// The same code paints the editing canvas and exports.
public struct CanvasRenderer {
    public var options: RenderOptions

    public init(options: RenderOptions = RenderOptions()) {
        self.options = options
    }

    /// Draws the page's layers; `visibleRect` (canvas points) lets off-screen layers be skipped.
    public func draw(page: Page, of document: Document, in context: CGContext, visibleRect: CGRect? = nil) {
        drawSiblings(page.layers, of: document, in: context, visibleRect: visibleRect)
    }

    /// Draws layers bottom to top; a mask clips every layer drawn after it.
    private func drawSiblings(_ ids: [LayerID], of document: Document, in context: CGContext, visibleRect: CGRect?, scope: SymbolScope = .root) {
        var openMasks = 0
        for id in ids {
            draw(id, of: document, in: context, visibleRect: visibleRect, scope: scope)
            guard let stored = document.layers[id] else { continue }
            let layer = scope.resolve(stored)
            guard layer.isMask, layer.isVisible, let clip = MaskShape.path(of: layer) else { continue }
            context.saveGState()
            openMasks += 1
            context.addPath(clip)
            context.clip(using: layer.vectorPath?.fillRule == .evenOdd ? .evenOdd : .winding)
        }
        for _ in 0..<openMasks { context.restoreGState() }
    }

    /// Draws one layer (and its contents) in its parent's coordinates. `scope` carries the
    /// overrides of the symbol instances being drawn.
    public func draw(_ id: LayerID, of document: Document, in context: CGContext, visibleRect: CGRect?, scope: SymbolScope = .root) {
        guard let stored = document.layers[id], id != options.hiddenLayer else { return }
        let layer = scope.resolve(stored)
        guard layer.isVisible, layer.opacity > 0 else { return }
        if let visibleRect, layer.rotation == 0, !paintBounds(of: layer).intersects(visibleRect) { return }

        context.saveGState()
        defer { context.restoreGState() }

        if layer.rotation != 0 {
            context.concatenate(layer.rotationTransform)
        }

        if let blur = layer.style.blur, blur.isEnabled, blur.radius > 0 {
            Offscreen.drawBlurred(
                in: context, userBounds: paintBounds(of: layer), radius: blur.radius,
                alpha: layer.opacity, blendMode: layer.style.blendMode.cgBlendMode
            ) { offscreen in
                drawContents(of: layer, document: document, in: offscreen, visibleRect: nil, scope: scope)
            }
            return
        }

        let needsLayer = layer.opacity < 1 || layer.style.blendMode != .normal
        if needsLayer {
            context.setAlpha(layer.opacity)
            context.setBlendMode(layer.style.blendMode.cgBlendMode)
            context.beginTransparencyLayer(auxiliaryInfo: nil)
        }
        drawContents(of: layer, document: document, in: context, visibleRect: visibleRect, scope: scope)
        if needsLayer { context.endTransparencyLayer() }
    }

    private func drawContents(of layer: Layer, document: Document, in context: CGContext, visibleRect: CGRect?, scope: SymbolScope) {
        let frame = layer.frame.cgRect
        switch layer.kind {
        case .artboard, .symbolMaster:
            drawArtboardBackground(layer, in: context)
            context.saveGState()
            context.clip(to: frame)
            drawChildren(of: layer, document: document, in: context, visibleRect: rotationFree(visibleRect, layer), scope: scope)
            context.restoreGState()
        case .group:
            // A group resized by an instance's layout scales its contents.
            let stored = document.layers[layer.id]?.frame ?? layer.frame
            let scale = CGSize(width: stored.width > 0 ? layer.frame.width / stored.width : 1,
                               height: stored.height > 0 ? layer.frame.height / stored.height : 1)
            drawChildren(of: layer, document: document, in: context, visibleRect: scale == CGSize(width: 1, height: 1) ? rotationFree(visibleRect, layer) : nil,
                         scope: scope, scale: scale)
        case .symbolInstance(let instance):
            drawInstance(instance, frame: frame, document: document, in: context, scope: scope)
        case .text(let content):
            TextLayout.draw(content, in: frame, context: context)
        case .image(let hash):
            let image = ImageCache.shared.image(hash: hash, data: document.images[hash])
            if layer.id == options.revealedCrop {
                context.saveGState()
                context.setAlpha(0.3)
                drawImage(image, in: layer.imageRectInParent, context: context)
                context.restoreGState()
            }
            StylePainter(context: context).paint(CGPath(rect: frame, transform: nil), frame: frame, style: layer.style, isOpen: false) { context in
                // A cropped image shows only the part of it inside the frame.
                context.saveGState()
                context.clip(to: frame)
                drawImage(image, in: layer.imageRectInParent, context: context)
                context.restoreGState()
            }
        case .rectangle, .oval, .line, .polygon, .star, .path:
            if let path = ShapePath.path(for: layer) {
                StylePainter(context: context, evenOdd: layer.vectorPath?.fillRule == .evenOdd)
                    .paint(path, frame: frame, style: layer.style, isOpen: ShapePath.isOpen(layer.kind))
            }
        }
    }

    /// A symbol's contents scaled into the instance's frame, with the instance's overrides.
    /// A missing symbol (or one nested too deep) shows as a dashed placeholder.
    private func drawInstance(_ instance: SymbolInstance, frame: CGRect, document: Document, in context: CGContext, scope: SymbolScope) {
        guard let masterID = document.master(of: instance.symbolID), let master = document.layers[masterID],
              let inner = scope.entering(instance, master: master, size: CGSizeValue(width: frame.width, height: frame.height), in: document) else {
            context.setStrokeColor(CGColor(gray: 0.5, alpha: 1))
            context.setLineDash(phase: 0, lengths: [4, 4])
            context.stroke(frame)
            return
        }
        context.saveGState()
        context.translateBy(x: frame.minX, y: frame.minY)
        let bounds = CGRect(origin: .zero, size: frame.size)
        context.clip(to: bounds)
        StylePainter(context: context).paint(CGPath(rect: bounds, transform: nil), frame: bounds, style: Style(fills: master.style.fills), isOpen: false)
        drawSiblings(master.children, of: document, in: context, visibleRect: nil, scope: inner)
        context.restoreGState()
    }

    private func drawArtboardBackground(_ layer: Layer, in context: CGContext) {
        let frame = layer.frame.cgRect
        StylePainter(context: context).paint(CGPath(rect: frame, transform: nil), frame: frame, style: layer.style, isOpen: false)
        if options.showsArtboardShadows {
            // A hairline edge, one device pixel wide at any zoom, so white artboards stand out.
            let pixel = 1 / Offscreen.scale(of: context.ctm)
            context.saveGState()
            context.setStrokeColor(CGColor(gray: 0, alpha: 0.12))
            context.setLineWidth(pixel)
            context.stroke(frame.insetBy(dx: -pixel / 2, dy: -pixel / 2))
            context.restoreGState()
        }
    }

    private func drawChildren(of layer: Layer, document: Document, in context: CGContext, visibleRect: CGRect?, scope: SymbolScope,
                              scale: CGSize = CGSize(width: 1, height: 1)) {
        let origin = layer.frame.cgRect.origin
        context.saveGState()
        context.translateBy(x: origin.x, y: origin.y)
        if scale != CGSize(width: 1, height: 1) { context.scaleBy(x: scale.width, y: scale.height) }
        let localVisible = visibleRect?.offsetBy(dx: -origin.x, dy: -origin.y)
        drawSiblings(layer.children, of: document, in: context, visibleRect: localVisible, scope: scope)
        context.restoreGState()
    }

    /// Draws a bitmap upright in a context whose y axis points down; a missing image shows a
    /// gray placeholder so the layer stays visible.
    private func drawImage(_ image: CGImage?, in frame: CGRect, context: CGContext) {
        guard let image else {
            context.setFillColor(CGColor(gray: 0.85, alpha: 1))
            context.fill(frame)
            return
        }
        context.saveGState()
        context.interpolationQuality = .high
        context.translateBy(x: 0, y: frame.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(x: frame.minX, y: 0, width: frame.width, height: frame.height))
        context.restoreGState()
    }

    /// The frame grown by outside borders and shadows, for skipping off-screen layers.
    private func paintBounds(of layer: Layer) -> CGRect {
        let style = layer.style
        let border = style.borders.filter(\.isEnabled).map { $0.position == .inside ? 0 : $0.width }.max() ?? 0
        let shadow = style.shadows.filter(\.isEnabled).map { max(abs($0.x), abs($0.y)) + $0.blur * 1.5 + max($0.spread, 0) }.max() ?? 0
        let blur = style.blur.map { $0.isEnabled ? $0.radius * 3 : 0 } ?? 0
        let outset = border + shadow + blur
        return layer.frame.cgRect.insetBy(dx: -outset, dy: -outset)
    }

    /// Culling inside rotated containers is skipped, as the visible rect would need rotating too.
    private func rotationFree(_ visibleRect: CGRect?, _ layer: Layer) -> CGRect? {
        layer.rotation == 0 ? visibleRect : nil
    }
}

/// Paints one path with a style: drop shadows, fills, inner shadows, then borders.
struct StylePainter {
    let context: CGContext
    /// Fill rule for paths whose subpaths overlap (holes in letters, boolean results).
    var evenOdd = false

    private var fillRule: CGPathFillRule { evenOdd ? .evenOdd : .winding }

    /// `content` (an image) is drawn over the fills and under inner shadows and borders.
    func paint(_ path: CGPath, frame: CGRect, style: Style, isOpen: Bool, content: ((CGContext) -> Void)? = nil) {
        let outline = isOpen ? strokeOutline(path, style: style) : path
        for shadow in style.shadows where shadow.isEnabled {
            drawDropShadow(shadow, of: outline)
        }
        if !isOpen {
            for fill in style.fills where fill.isEnabled {
                drawFill(fill, path: path, frame: frame)
            }
            content?(context)
            for shadow in style.innerShadows where shadow.isEnabled {
                drawInnerShadow(shadow, of: path)
            }
        }
        for border in style.borders where border.isEnabled && border.width > 0 {
            drawBorder(border, path: path, isOpen: isOpen)
        }
    }

    private func drawFill(_ fill: Fill, path: CGPath, frame: CGRect) {
        guard let gradient = fill.gradient, gradient.stops.count > 0 else {
            context.addPath(path)
            context.setFillColor(fill.color.cgColor)
            context.fillPath(using: fillRule)
            return
        }
        let stops = gradient.stops.sorted { $0.position < $1.position }
        guard let cgGradient = CGGradient(
            colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
            colors: stops.map(\.color.cgColor) as CFArray,
            locations: stops.map { CGFloat($0.position) }
        ) else { return }
        let start = ShapePath.point(gradient.from, in: frame)
        let end = ShapePath.point(gradient.to, in: frame)
        context.saveGState()
        context.addPath(path)
        context.clip(using: fillRule)
        switch gradient.kind {
        case .linear:
            context.drawLinearGradient(cgGradient, start: start, end: end, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        case .radial:
            // Radial gradients are elliptical: a circle around the center, stretched to the frame.
            let radius = max(hypot((gradient.to.x - gradient.from.x) * frame.width, (gradient.to.y - gradient.from.y) * frame.height), 0.001)
            context.drawRadialGradient(cgGradient, startCenter: start, startRadius: 0, endCenter: start, endRadius: radius, options: [.drawsAfterEndLocation])
        }
        context.restoreGState()
    }

    private func drawBorder(_ border: Border, path: CGPath, isOpen: Bool) {
        context.saveGState()
        defer { context.restoreGState() }
        var width = border.width
        let position = isOpen ? .center : border.position
        switch position {
        case .center:
            break
        case .inside:
            context.addPath(path)
            context.clip()
            width *= 2
        case .outside:
            // Clip to everything except the shape's interior.
            context.addRect(path.boundingBoxOfPath.insetBy(dx: -width * 2 - 1, dy: -width * 2 - 1))
            context.addPath(path)
            context.clip(using: .evenOdd)
            width *= 2
        }
        context.addPath(path)
        context.setStrokeColor(border.color.cgColor)
        context.setLineWidth(width)
        context.setLineCap(border.cap.cgLineCap)
        context.setLineJoin(border.join.cgLineJoin)
        let dashes = border.dashes.filter { $0 > 0 }
        if !dashes.isEmpty { context.setLineDash(phase: 0, lengths: dashes.map { CGFloat($0) }) }
        context.strokePath()
    }

    /// The shape (grown by spread) moved by the offset, blurred, and kept outside the shape itself,
    /// so transparent fills do not reveal the shadow underneath.
    private func drawDropShadow(_ shadow: Shadow, of path: CGPath) {
        var offset = CGAffineTransform(translationX: shadow.x, y: shadow.y)
        guard let shadowPath = spread(path, by: shadow.spread).copy(using: &offset) else { return }
        let reach = shadow.blur * 1.5 + 2
        let bounds = shadowPath.boundingBoxOfPath.insetBy(dx: -reach, dy: -reach)

        context.saveGState()
        context.addRect(bounds.union(path.boundingBoxOfPath).insetBy(dx: -1, dy: -1))
        context.addPath(path)
        context.clip(using: .evenOdd)
        fillBlurred(shadowPath, color: shadow.color, blur: shadow.blur, bounds: bounds, evenOdd: false)
        context.restoreGState()
    }

    /// A ring around the shape, moved by the offset and blurred, clipped to the shape's inside.
    private func drawInnerShadow(_ shadow: Shadow, of path: CGPath) {
        let bounds = path.boundingBoxOfPath
        let margin = abs(shadow.x) + abs(shadow.y) + shadow.blur * 3 + abs(shadow.spread) + 10
        let ring = CGMutablePath()
        ring.addRect(bounds.insetBy(dx: -margin, dy: -margin))
        ring.addPath(path, transform: CGAffineTransform(translationX: shadow.x, y: shadow.y))
        if shadow.spread > 0 {
            let grown = path.copy(strokingWithWidth: shadow.spread * 2, lineCap: .round, lineJoin: .round, miterLimit: 4)
            ring.addPath(grown, transform: CGAffineTransform(translationX: shadow.x, y: shadow.y))
        }

        context.saveGState()
        context.addPath(path)
        context.clip()
        fillBlurred(ring, color: shadow.color, blur: shadow.blur, bounds: bounds.insetBy(dx: -2, dy: -2), evenOdd: true)
        context.restoreGState()
    }

    private func fillBlurred(_ path: CGPath, color: Color, blur: Double, bounds: CGRect, evenOdd: Bool) {
        let fill = { (target: CGContext) in
            target.addPath(path)
            target.setFillColor(color.cgColor)
            target.fillPath(using: evenOdd ? .evenOdd : .winding)
        }
        if blur > 0 {
            Offscreen.drawBlurred(in: context, userBounds: bounds, radius: blur, draw: fill)
        } else {
            fill(context)
        }
    }

    /// The shape grown by `spread` (shrinking is not supported for drop shadows).
    private func spread(_ path: CGPath, by amount: Double) -> CGPath {
        guard amount > 0 else { return path }
        let outline = path.copy(strokingWithWidth: amount * 2, lineCap: .round, lineJoin: .round, miterLimit: 4)
        return path.union(outline)
    }

    /// Lines cast shadows from their stroked shape.
    private func strokeOutline(_ path: CGPath, style: Style) -> CGPath {
        let width = style.borders.filter(\.isEnabled).map(\.width).max() ?? 1
        return path.copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 4)
    }
}

extension Color {
    public var cgColor: CGColor {
        let c = components
        return CGColor(srgbRed: c.red, green: c.green, blue: c.blue, alpha: c.alpha)
    }
}

extension BlendMode {
    var cgBlendMode: CGBlendMode {
        switch self {
        case .normal: .normal
        case .darken: .darken
        case .multiply: .multiply
        case .colorBurn: .colorBurn
        case .lighten: .lighten
        case .screen: .screen
        case .colorDodge: .colorDodge
        case .overlay: .overlay
        case .softLight: .softLight
        case .hardLight: .hardLight
        case .difference: .difference
        case .exclusion: .exclusion
        case .hue: .hue
        case .saturation: .saturation
        case .color: .color
        case .luminosity: .luminosity
        }
    }
}
