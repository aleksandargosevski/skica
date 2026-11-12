import AppKit
import SkicaCore

/// Draws editor chrome in view coordinates: artboard titles, hover and selection outlines,
/// resize handles, the size label and the marquee.
struct CanvasOverlay {
    let document: Document
    let page: Page
    let selection: [LayerID]
    let hovered: LayerID?
    let viewport: Viewport
    let marquee: CGRect?
    let showsHandles: Bool
    let guides: [SnapGuide]
    /// Hint labels with the letters typed so far; only labels starting with them are shown.
    let hints: [(label: String, id: LayerID, typed: String)]
    let pen: PenSession?
    let pathEdit: PathEditState?
    /// While cropping: the crop and the whole image, in page coordinates.
    var crop: (frame: CGRect, image: CGRect)?

    static let guideColor = NSColor(srgbRed: 1, green: 0.23, blue: 0.42, alpha: 1)

    private var accent: NSColor { .controlAccentColor }

    func draw() {
        if pathEdit != nil || pen != nil { return drawVectorEditing() }
        if let crop { return drawCrop(crop) }
        drawArtboardTitles()
        if let hovered, !selection.contains(hovered) {
            outline(hovered, width: 2)
        }
        for id in selection {
            outline(id, width: 1)
        }
        if let box = document.worldBounds(of: selection) {
            let viewBox = viewport.toView(box).integral
            if selection.count > 1 {
                accent.withAlphaComponent(0.6).setStroke()
                let path = NSBezierPath(rect: viewBox.insetBy(dx: 0.5, dy: 0.5))
                path.lineWidth = 1
                path.stroke()
            }
            if showsHandles { drawHandles(viewBox) }
            drawSizeLabel(for: box, below: viewBox)
        }
        if !guides.isEmpty {
            let path = NSBezierPath()
            for guide in guides {
                path.move(to: viewport.toView(guide.start).pixelAligned)
                path.line(to: viewport.toView(guide.end).pixelAligned)
            }
            Self.guideColor.setStroke()
            path.lineWidth = 1
            path.stroke()
        }
        drawHints()
        if let marquee {
            let rect = viewport.toView(marquee)
            accent.withAlphaComponent(0.08).setFill()
            rect.fill()
            accent.withAlphaComponent(0.7).setStroke()
            NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5)).stroke()
        }
    }

    // MARK: Vector editing

    /// While drawing with the pen or editing points: the path, its points and selected handles.
    private func drawVectorEditing() {
        drawArtboardTitles()
        drawGuidesIfAny()
        if let pen { drawPen(pen) }
        guard let edit = pathEdit, let layer = document.layers[edit.layerID], let vector = layer.vectorPath else { return }
        let transform = CGAffineTransform(translationX: layer.frame.x, y: layer.frame.y)
            .concatenating(document.worldTransform(of: edit.layerID))
        let toView = { (point: CGPoint) in viewport.toView(point.applying(transform)) }

        if let outline = document.worldPath(of: edit.layerID) {
            var viewTransform = CGAffineTransform(translationX: -viewport.origin.x, y: -viewport.origin.y)
                .concatenating(CGAffineTransform(scaleX: viewport.zoom, y: viewport.zoom))
            if let path = outline.copy(using: &viewTransform) {
                let bezier = NSBezierPath(cgPath: path)
                bezier.lineWidth = 1
                accent.setStroke()
                bezier.stroke()
            }
        }
        for ref in edit.selected.sorted() {
            guard let point = vector[ref] else { continue }
            for handle in [point.curveIn, point.curveOut].compactMap({ $0 }) {
                let line = NSBezierPath()
                line.move(to: toView(point.point))
                line.line(to: toView(handle))
                accent.withAlphaComponent(0.7).setStroke()
                line.lineWidth = 1
                line.stroke()
                let dot = CGRect(x: toView(handle).x - 3.5, y: toView(handle).y - 3.5, width: 7, height: 7)
                NSColor.white.setFill()
                NSBezierPath(ovalIn: dot).fill()
                accent.setStroke()
                NSBezierPath(ovalIn: dot.insetBy(dx: 0.5, dy: 0.5)).stroke()
            }
        }
        for ref in vector.pointRefs {
            guard let point = vector[ref] else { continue }
            drawPoint(toView(point.point), selected: edit.selected.contains(ref), smooth: point.mode != .straight)
        }
    }

    private func drawPen(_ pen: PenSession) {
        let points = pen.points
        guard let last = points.last else { return }
        if let preview = pen.preview {
            let line = NSBezierPath()
            line.move(to: viewport.toView(last.point))
            if let handle = last.curveOut {
                line.curve(to: viewport.toView(preview), controlPoint1: viewport.toView(handle), controlPoint2: viewport.toView(preview))
            } else {
                line.line(to: viewport.toView(preview))
            }
            accent.withAlphaComponent(0.6).setStroke()
            line.setLineDash([4, 3], count: 2, phase: 0)
            line.lineWidth = 1
            line.stroke()
        }
        for handle in [last.curveIn, last.curveOut].compactMap({ $0 }) {
            let line = NSBezierPath()
            line.move(to: viewport.toView(last.point))
            line.line(to: viewport.toView(handle))
            accent.setStroke()
            line.stroke()
        }
        for (index, point) in points.enumerated() {
            let closable = index == 0 && points.count >= 2 && pen.preview.map { hypot(viewport.toView($0).x - viewport.toView(point.point).x, viewport.toView($0).y - viewport.toView(point.point).y) < 8 } == true
            drawPoint(viewport.toView(point.point), selected: index == points.count - 1 || closable, smooth: point.mode != .straight)
        }
    }

    private func drawPoint(_ center: CGPoint, selected: Bool, smooth: Bool) {
        let rect = CGRect(x: center.x - 4, y: center.y - 4, width: 8, height: 8)
        let shape = smooth ? NSBezierPath(ovalIn: rect) : NSBezierPath(rect: rect)
        (selected ? accent : NSColor.white).setFill()
        shape.fill()
        accent.setStroke()
        shape.lineWidth = 1
        shape.stroke()
    }

    private func drawGuidesIfAny() {
        guard !guides.isEmpty else { return }
        let path = NSBezierPath()
        for guide in guides {
            path.move(to: viewport.toView(guide.start).pixelAligned)
            path.line(to: viewport.toView(guide.end).pixelAligned)
        }
        Self.guideColor.setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    private func drawHints() {
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .bold)
        for hint in hints where hint.label.hasPrefix(hint.typed) {
            guard let bounds = document.worldBounds(of: hint.id) else { continue }
            let rect = viewport.toView(bounds)
            let typed = NSAttributedString(string: hint.typed, attributes: [.font: font, .foregroundColor: NSColor.black.withAlphaComponent(0.35)])
            let rest = NSAttributedString(string: String(hint.label.dropFirst(hint.typed.count)).uppercased(), attributes: [.font: font, .foregroundColor: NSColor.black])
            let text = NSMutableAttributedString(attributedString: typed)
            text.append(rest)
            let size = text.size()
            let pill = CGRect(x: rect.minX, y: rect.minY, width: size.width + 8, height: size.height + 4)
            NSColor(srgbRed: 1, green: 0.84, blue: 0.2, alpha: 1).setFill()
            NSBezierPath(roundedRect: pill, xRadius: 4, yRadius: 4).fill()
            NSColor.black.withAlphaComponent(0.25).setStroke()
            NSBezierPath(roundedRect: pill.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4).stroke()
            text.draw(at: CGPoint(x: pill.minX + 4, y: pill.minY + 2))
        }
    }

    /// Title rectangles above top-level artboards, in view coordinates; also used for clicks.
    static func artboardTitles(document: Document, page: Page, viewport: Viewport) -> [(id: LayerID, rect: CGRect, name: String)] {
        document.topLevelLayers(of: page).compactMap { layer in
            guard layer.isArtboard, layer.isVisible else { return nil }
            let rect = viewport.toView(layer.frame.cgRect)
            let width = min(max(rect.width, 40), titleWidth(layer.name) + 4)
            return (layer.id, CGRect(x: rect.minX, y: rect.minY - 20, width: width, height: 18), layer.name)
        }
    }

    private static let titleAttributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11)]

    private static func titleWidth(_ name: String) -> CGFloat {
        (name as NSString).size(withAttributes: titleAttributes).width
    }

    private func drawArtboardTitles() {
        for title in Self.artboardTitles(document: document, page: page, viewport: viewport) {
            let isActive = selection.contains(title.id) || hovered == title.id
            var attributes = Self.titleAttributes
            attributes[.foregroundColor] = isActive ? accent : NSColor.secondaryLabelColor
            let maxWidth = max(viewport.toView(document.layers[title.id]?.frame.cgRect ?? .zero).width, 40)
            (title.name as NSString).draw(
                with: CGRect(x: title.rect.minX, y: title.rect.minY + 2, width: maxWidth, height: 16),
                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                attributes: attributes
            )
        }
    }

    private func outline(_ id: LayerID, width: CGFloat) {
        guard let layer = document.layers[id] else { return }
        let path = NSBezierPath()
        if !layer.isContainer, let shape = document.worldPath(of: id) {
            var toView = CGAffineTransform(translationX: -viewport.origin.x, y: -viewport.origin.y)
                .concatenating(CGAffineTransform(scaleX: viewport.zoom, y: viewport.zoom))
            if let viewPath = shape.copy(using: &toView) { path.append(NSBezierPath(cgPath: viewPath)) }
        }
        if layer.isContainer || layer.rotation != 0 || selection.contains(id) {
            let corners = document.worldCorners(of: id).map(viewport.toView)
            if let first = corners.first {
                path.move(to: first)
                corners.dropFirst().forEach(path.line(to:))
                path.close()
            }
        }
        accent.setStroke()
        path.lineWidth = width
        path.stroke()
    }

    /// The whole image dashed, the crop solid with its handles and size.
    private func drawCrop(_ crop: (frame: CGRect, image: CGRect)) {
        let image = NSBezierPath(rect: viewport.toView(crop.image).integral.insetBy(dx: 0.5, dy: 0.5))
        image.setLineDash([4, 3], count: 2, phase: 0)
        image.lineWidth = 1
        accent.withAlphaComponent(0.7).setStroke()
        image.stroke()
        let viewBox = viewport.toView(crop.frame).integral
        let frame = NSBezierPath(rect: viewBox.insetBy(dx: 0.5, dy: 0.5))
        frame.lineWidth = 1.5
        accent.setStroke()
        frame.stroke()
        drawHandles(viewBox)
        drawSizeLabel(for: crop.frame, below: viewBox)
    }

    private func drawHandles(_ box: CGRect) {
        for handle in SelectionHandle.allCases {
            let center = handle.point(in: box)
            let rect = CGRect(x: center.x - 3.5, y: center.y - 3.5, width: 7, height: 7)
            NSColor.white.setFill()
            rect.fill()
            accent.setStroke()
            let path = NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5))
            path.lineWidth = 1
            path.stroke()
        }
    }

    private func drawSizeLabel(for box: CGRect, below viewBox: CGRect) {
        let text = "\(Self.format(box.width)) × \(Self.format(box.height))" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let size = text.size(withAttributes: attributes)
        let pill = CGRect(x: viewBox.midX - size.width / 2 - 5, y: viewBox.maxY + 8, width: size.width + 10, height: size.height + 4)
        accent.setFill()
        NSBezierPath(roundedRect: pill, xRadius: 3, yRadius: 3).fill()
        text.draw(at: CGPoint(x: pill.minX + 5, y: pill.minY + 2), withAttributes: attributes)
    }

    static func format(_ value: CGFloat) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
    }
}

extension CGPoint {
    /// Centered on a pixel, so one-point lines stay crisp.
    var pixelAligned: CGPoint { CGPoint(x: x.rounded() + 0.5, y: y.rounded() + 0.5) }
}

/// The eight resize handles around a selection.
enum SelectionHandle: CaseIterable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

    /// Which edges the handle moves: -1 the left/top one, 1 the right/bottom one, 0 neither.
    var edges: (x: Int, y: Int) {
        switch self {
        case .topLeft: (-1, -1)
        case .top: (0, -1)
        case .topRight: (1, -1)
        case .right: (1, 0)
        case .bottomRight: (1, 1)
        case .bottom: (0, 1)
        case .bottomLeft: (-1, 1)
        case .left: (-1, 0)
        }
    }

    func point(in box: CGRect) -> CGPoint {
        let x = [box.minX, box.midX, box.maxX][edges.x + 1]
        let y = [box.minY, box.midY, box.maxY][edges.y + 1]
        return CGPoint(x: x, y: y)
    }

    var cursor: NSCursor {
        switch self {
        case .left, .right: .resizeLeftRight
        case .top, .bottom: .resizeUpDown
        default: .crosshair
        }
    }

    /// The handle within reach of `point`; corners win over edges. Small boxes only offer corners.
    static func handle(at point: CGPoint, box: CGRect, reach: CGFloat = 6) -> SelectionHandle? {
        let small = box.width < 24 || box.height < 24
        return allCases
            .filter { !small || ($0.edges.x != 0 && $0.edges.y != 0) }
            .sorted { abs($0.edges.x) + abs($0.edges.y) > abs($1.edges.x) + abs($1.edges.y) }
            .first { handle in
                let center = handle.point(in: box)
                return abs(point.x - center.x) <= reach && abs(point.y - center.y) <= reach
            }
    }

    /// The box after dragging `handle` by `delta` (page units). The result can have a negative
    /// size when dragged past the opposite edge, which flips the selection.
    static func resizedBox(_ box: CGRect, handle: SelectionHandle, by delta: CGVector, keepAspect: Bool, fromCenter: Bool) -> CGRect {
        var minX = box.minX, maxX = box.maxX, minY = box.minY, maxY = box.maxY
        let edges = handle.edges
        if edges.x == -1 { minX += delta.dx } else if edges.x == 1 { maxX += delta.dx }
        if edges.y == -1 { minY += delta.dy } else if edges.y == 1 { maxY += delta.dy }

        if keepAspect, box.width > 0, box.height > 0 {
            let scaleX = (maxX - minX) / box.width
            let scaleY = (maxY - minY) / box.height
            let scale = edges.x == 0 ? scaleY : edges.y == 0 ? scaleX : (abs(scaleX) > abs(scaleY) ? scaleX : scaleY)
            let width = box.width * scale
            let height = box.height * scale
            switch edges.x {
            case 1: maxX = minX + width
            case -1: minX = maxX - width
            default: minX = box.midX - width / 2; maxX = minX + width
            }
            switch edges.y {
            case 1: maxY = minY + height
            case -1: minY = maxY - height
            default: minY = box.midY - height / 2; maxY = minY + height
            }
        }
        if fromCenter {
            if edges.x == 1 { minX = 2 * box.midX - maxX } else if edges.x == -1 { maxX = 2 * box.midX - minX }
            if edges.y == 1 { minY = 2 * box.midY - maxY } else if edges.y == -1 { maxY = 2 * box.midY - minY }
        }
        return CGRect(x: minX.rounded(), y: minY.rounded(), width: (maxX - minX).rounded(), height: (maxY - minY).rounded())
    }
}
