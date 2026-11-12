import CoreGraphics
import Foundation

public enum BooleanOperation: String, CaseIterable, Sendable {
    case union, subtract, intersect, difference

    public var title: String {
        switch self {
        case .union: "Union"
        case .subtract: "Subtract"
        case .intersect: "Intersect"
        case .difference: "Difference"
        }
    }
}

extension Transaction {
    /// Keeps path frames wrapped around their points: after the points change, the frame moves
    /// to their bounds; after only the frame is resized, the points scale with it.
    public mutating func fitPaths() {
        for id in touched {
            guard let layer = document.layers[id], var vector = layer.vectorPath else { continue }
            let before = original.layers[id]
            var frame = layer.frame

            if let before, before.vectorPath == vector, before.frame != layer.frame {
                let scaleX = before.frame.width > 0.001 ? layer.frame.width / before.frame.width : 1
                let scaleY = before.frame.height > 0.001 ? layer.frame.height / before.frame.height : 1
                guard scaleX != 1 || scaleY != 1 else { continue }
                vector = vector.applying(CGAffineTransform(scaleX: scaleX, y: scaleY))
            } else if before?.vectorPath != vector {
                let bounds = vector.bounds
                guard bounds.origin != .zero || bounds.width != frame.width || bounds.height != frame.height else { continue }
                vector = vector.applying(CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY))
                let oldCenter = CGPoint(x: frame.x + frame.width / 2, y: frame.y + frame.height / 2)
                frame = Rect(x: frame.x + bounds.minX, y: frame.y + bounds.minY, width: bounds.width, height: bounds.height)
                if layer.rotation != 0 {
                    // The frame's center (the rotation pivot) moved; shift so nothing jumps on screen.
                    let newCenter = CGPoint(x: frame.x + frame.width / 2, y: frame.y + frame.height / 2)
                    let moved = CGVector(dx: newCenter.x - oldCenter.x, dy: newCenter.y - oldCenter.y)
                    let rotated = CGPoint(x: moved.dx, y: moved.dy).applying(CGAffineTransform(rotationAngle: layer.rotation * .pi / 180))
                    frame.x += rotated.x - moved.dx
                    frame.y += rotated.y - moved.dy
                }
            } else {
                continue
            }
            let fitted = frame
            let fittedVector = vector
            update(id) { layer in
                layer.kind = .path(fittedVector)
                layer.frame = fitted
            }
        }
    }

    /// Turns shapes into editable paths that look the same (text into letter outlines).
    /// Returns the layers that are now paths.
    @discardableResult
    public mutating func convertToPaths(_ ids: [LayerID]) -> [LayerID] {
        var converted: [LayerID] = []
        for id in document.topmostOnly(ids) {
            guard let layer = document.layers[id] else { continue }
            switch layer.kind {
            case .rectangle, .oval, .line, .polygon, .star:
                var atOrigin = layer
                atOrigin.frame.x = 0
                atOrigin.frame.y = 0
                guard let path = ShapePath.path(for: atOrigin) else { continue }
                var vector = VectorPath(path)
                if case .line = layer.kind { vector.subpaths = vector.subpaths.map { Subpath(points: $0.points, isClosed: false) } }
                update(id) { $0.kind = .path(vector) }
                converted.append(id)
            case .text(let content):
                converted += outlineText(id, content: content)
            case .path:
                converted.append(id)
            case .artboard, .symbolMaster, .symbolInstance, .group, .image:
                continue
            }
        }
        return converted
    }

    /// Replaces a text layer with its letters as paths (one per color), keeping its place.
    private mutating func outlineText(_ id: LayerID, content: TextContent) -> [LayerID] {
        guard let layer = document.layers[id], let parent = document.parentRef(of: id),
              let index = document.childIDs(of: parent).firstIndex(of: id) else { return [] }
        let local = CGRect(origin: .zero, size: layer.frame.cgRect.size)
        let outlines = TextLayout.outlines(of: content, in: local)
        guard !outlines.isEmpty else { return [] }

        if outlines.count == 1, let outline = outlines.first {
            update(id) { layer in
                layer.kind = .path(VectorPath(outline.path))
                layer.style.fills = [Fill(outline.color)]
            }
            return [id]
        }
        // Several colors: a group of paths in the text's place.
        let group = Layer(name: layer.name, kind: .group, frame: layer.frame, rotation: layer.rotation, opacity: layer.opacity)
        remove(id)
        insert(group, into: parent, at: index)
        for (number, outline) in outlines.enumerated() {
            let path = Layer(name: "\(layer.name) \(number + 1)", kind: .path(VectorPath(outline.path)),
                             frame: Rect(x: 0, y: 0, width: 0, height: 0), style: Style(fills: [Fill(outline.color)]))
            insert(path, into: .layer(group.id))
        }
        return [group.id]
    }

    /// Turns a shape's first border into a filled shape of its own, placed above the layer.
    /// The border is removed; a layer that had no visible fill is replaced entirely.
    @discardableResult
    public mutating func outlineBorders(_ ids: [LayerID]) -> [LayerID] {
        var outlines: [LayerID] = []
        for id in document.topmostOnly(ids) {
            guard let layer = document.layers[id], !layer.isContainer, layer.textContent == nil, layer.imageHash == nil,
                  let border = layer.style.borders.first(where: { $0.isEnabled && $0.width > 0 }),
                  var shape = ShapePath.path(for: layer),
                  let parent = document.parentRef(of: id),
                  let index = document.childIDs(of: parent).firstIndex(of: id) else { continue }
            var rotation = layer.rotationTransform
            shape = shape.copy(using: &rotation) ?? shape
            let isOpen = ShapePath.isOpen(layer.kind)
            let position = isOpen ? .center : border.position
            let width = position == .center ? border.width : border.width * 2
            var outline = shape.copy(strokingWithWidth: width, lineCap: border.cap.cgLineCap, lineJoin: border.join.cgLineJoin, miterLimit: 10)
            switch position {
            case .center: break
            case .inside: outline = outline.intersection(shape)
            case .outside: outline = outline.subtracting(shape)
            }
            let result = Layer(name: layer.name + " Outline", kind: .path(VectorPath(outline)), frame: Rect(x: 0, y: 0, width: 0, height: 0),
                               style: Style(fills: [Fill(border.color)], shadows: layer.style.shadows))
            insert(result, into: parent, at: index + 1)
            outlines.append(result.id)
            if isOpen || !layer.style.fills.contains(where: \.isEnabled) {
                remove(id)
            } else {
                update(id) { $0.style.borders.removeAll { $0 == border } }
            }
        }
        return outlines
    }

    /// Combines shapes into one path with the style of the bottom one, in the place of the top
    /// one. Only shapes that share the bottom one's parent take part. Returns the new layer.
    @discardableResult
    public mutating func combine(_ ids: [LayerID], _ operation: BooleanOperation) -> LayerID? {
        let candidates = document.topmostOnly(ids)
        guard let first = candidates.first, let parent = document.parentRef(of: first) else { return nil }
        let siblings = document.childIDs(of: parent)
        let ordered = siblings.filter(candidates.contains)
        let shapes = ordered.compactMap { id -> (id: LayerID, path: CGPath)? in
            guard let layer = document.layers[id], let path = booleanShape(of: layer) else { return nil }
            return (id, path)
        }
        guard shapes.count >= 2, let bottom = document.layers[shapes[0].id],
              let topIndex = shapes.compactMap({ siblings.firstIndex(of: $0.id) }).max() else { return nil }

        var result = shapes[0].path
        for shape in shapes.dropFirst() {
            switch operation {
            case .union: result = result.union(shape.path)
            case .subtract: result = result.subtracting(shape.path)
            case .intersect: result = result.intersection(shape.path)
            case .difference: result = result.symmetricDifference(shape.path)
            }
        }
        var style = bottom.style
        if style.fills.isEmpty, style.borders.isEmpty { style.fills = [Fill(Tool.defaultFill)] }
        let combined = Layer(name: operation.title, kind: .path(VectorPath(result, fillRule: .evenOdd)),
                             frame: Rect(x: 0, y: 0, width: 0, height: 0), opacity: bottom.opacity, style: style)
        insert(combined, into: parent, at: topIndex + 1)
        for shape in shapes { remove(shape.id) }
        return combined.id
    }

    /// A layer's filled area in its parent's coordinates, for boolean operations.
    private func booleanShape(of layer: Layer) -> CGPath? {
        var outline: CGPath
        switch layer.kind {
        case .rectangle, .oval, .polygon, .star, .path:
            guard let path = ShapePath.path(for: layer) else { return nil }
            outline = path
        case .text(let content):
            let local = CGRect(origin: .zero, size: layer.frame.cgRect.size)
            let letters = CGMutablePath()
            for outline in TextLayout.outlines(of: content, in: local) { letters.addPath(outline.path) }
            outline = letters.copy(using: [CGAffineTransform(translationX: layer.frame.x, y: layer.frame.y)]) ?? letters
        case .line, .artboard, .symbolMaster, .symbolInstance, .group, .image:
            return nil
        }
        var rotation = layer.rotationTransform
        return outline.copy(using: &rotation)
    }
}

private extension CGPath {
    func copy(using transforms: [CGAffineTransform]) -> CGPath? {
        var transform = transforms.reduce(CGAffineTransform.identity) { $0.concatenating($1) }
        return copy(using: &transform)
    }
}

extension Border.Cap {
    public var cgLineCap: CGLineCap {
        switch self {
        case .butt: .butt
        case .round: .round
        case .square: .square
        }
    }
}

extension Border.Join {
    public var cgLineJoin: CGLineJoin {
        switch self {
        case .miter: .miter
        case .round: .round
        case .bevel: .bevel
        }
    }
}
