import CoreGraphics
import Foundation

public enum ReorderDirection: Sendable {
    case forward, backward, front, back
}

/// Editing operations, all expressed on page (world) coordinates where that makes sense.
extension Transaction {
    /// Moves layers by a page offset; layers inside another moved layer move with it.
    public mutating func move(_ ids: [LayerID], by delta: CGVector) {
        for id in document.topmostOnly(ids) {
            let local = document.vectorInParentSpace(delta, of: id)
            update(id) { layer in
                layer.frame.x += local.dx
                layer.frame.y += local.dy
            }
        }
    }

    /// Stretches layers so that `oldBox` (their page bounds) becomes `newBox`. Dragging past the
    /// opposite edge flips the box; shapes keep positive sizes and lines swap their ends.
    /// `newBox` may have a negative size (CGRect's `width`/`height` would hide that, so `size` is used).
    public mutating func resize(_ ids: [LayerID], from oldBox: CGRect, to newBox: CGRect) {
        let oldBox = oldBox.standardized
        let scaleX = oldBox.width > 0 ? newBox.size.width / oldBox.width : 1
        let scaleY = oldBox.height > 0 ? newBox.size.height / oldBox.height : 1

        for id in document.topmostOnly(ids) {
            guard let layer = document.layers[id] else { continue }
            let space = document.parentSpace(of: id)
            let world = layer.frame.cgRect.applying(space)
            let mapped = CGRect(
                x: newBox.origin.x + (world.minX - oldBox.minX) * scaleX,
                y: newBox.origin.y + (world.minY - oldBox.minY) * scaleY,
                width: world.width * scaleX,
                height: world.height * scaleY
            ).standardized
            let local = mapped.applying(space.inverted())
            let before = layer
            update(id) { layer in
                layer.frame = Rect(local)
                if case .line(var from, var to) = layer.kind {
                    if scaleX < 0 { from.x = 1 - from.x; to.x = 1 - to.x }
                    if scaleY < 0 { from.y = 1 - from.y; to.y = 1 - to.y }
                    layer.kind = .line(from: from, to: to)
                }
                if case .path(let vector) = layer.kind {
                    layer.kind = .path(Self.scaled(vector, from: before.frame, to: local, flipX: scaleX < 0, flipY: scaleY < 0))
                }
            }
        }
    }

    /// Grows (or shrinks, with negative values) layers by moving their right and bottom edges,
    /// or the left and top edges with `fromOpposite`.
    public mutating func resizeEdges(_ ids: [LayerID], dx: Double, dy: Double, fromOpposite: Bool) {
        for id in document.topmostOnly(ids) {
            update(id) { layer in
                let width = max(layer.frame.width + dx, 0)
                let height = max(layer.frame.height + dy, 0)
                if fromOpposite {
                    layer.frame.x -= width - layer.frame.width
                    layer.frame.y -= height - layer.frame.height
                }
                layer.frame.width = width
                layer.frame.height = height
            }
        }
    }

    public mutating func reorder(_ ids: [LayerID], _ direction: ReorderDirection) {
        let selected = Set(ids)
        let parents = Set(ids.compactMap(document.parentRef(of:)))
        for parent in parents {
            var children = document.childIDs(of: parent)
            let isSelected = { (id: LayerID) in selected.contains(id) }
            switch direction {
            case .forward:
                for index in stride(from: children.count - 2, through: 0, by: -1)
                where isSelected(children[index]) && !isSelected(children[index + 1]) {
                    children.swapAt(index, index + 1)
                }
            case .backward:
                for index in children.indices.dropFirst() where isSelected(children[index]) && !isSelected(children[index - 1]) {
                    children.swapAt(index, index - 1)
                }
            case .front:
                children = children.filter { !isSelected($0) } + children.filter(isSelected)
            case .back:
                children = children.filter(isSelected) + children.filter { !isSelected($0) }
            }
            setChildren(children, of: parent)
        }
    }

    /// Moves a layer to another parent without changing where it appears on the page.
    public mutating func reparent(_ id: LayerID, to parent: LayerParent, at index: Int? = nil) {
        guard let layer = document.layers[id], document.parentRef(of: id) != parent else { return }
        let worldOrigin = CGPoint(x: layer.frame.x, y: layer.frame.y).applying(document.parentSpace(of: id))
        detach(id)
        attach(id, to: parent, at: index)
        let local = worldOrigin.applying(document.parentSpace(of: id).inverted())
        update(id) { layer in
            layer.frame.x = local.x
            layer.frame.y = local.y
        }
    }

    /// Moves layers into `parent` (the layers list's drag and drop) so that they sit together
    /// below the child now at `index` (counted from the bottom; past the end is the top), keeping
    /// their order among themselves and where they appear on the page. Returns the moved layers.
    @discardableResult
    public mutating func move(_ ids: [LayerID], into parent: LayerParent, at index: Int) -> [LayerID] {
        let topmost = document.topmostOnly(ids)
        guard !topmost.isEmpty, document.canMove(topmost, into: parent), let pageID = document.pageID(of: topmost[0]),
              let page = document.page(pageID) else { return [] }
        // Bottom to top, so each one lands above the previous one.
        let order = document.listOrder(of: page)
        let moving = topmost.sorted { (order.firstIndex(of: $0) ?? 0) > (order.firstIndex(of: $1) ?? 0) }
        let children = document.childIDs(of: parent)
        // The first child at or above the drop point that stays; the moved layers go right below it.
        let anchor = children.dropFirst(min(max(index, 0), children.count)).first { !moving.contains($0) }

        let origins = moving.map { id -> CGPoint in
            let frame = document.layers[id]!.frame
            return CGPoint(x: frame.x, y: frame.y).applying(document.parentSpace(of: id))
        }
        for id in moving { detach(id) }
        for (id, origin) in zip(moving, origins) {
            let position = anchor.flatMap { document.childIDs(of: parent).firstIndex(of: $0) }
            attach(id, to: parent, at: position)
            let local = origin.applying(document.parentSpace(of: id).inverted())
            update(id) { layer in
                layer.frame.x = local.x
                layer.frame.y = local.y
            }
        }
        return moving
    }

    /// After a move, puts layers into the artboard under their center, or onto the page when
    /// they left all artboards. Artboards and layers inside groups stay where they are.
    public mutating func adoptIntoArtboards(_ ids: [LayerID], on pageID: PageID) {
        for id in document.topmostOnly(ids) {
            guard let layer = document.layers[id], !layer.isArtboard else { continue }
            let currentParent = layer.parent.flatMap { document.layers[$0] }
            guard currentParent == nil || currentParent?.isArtboard == true,
                  let bounds = document.worldBounds(of: id) else { continue }
            let center = CGPoint(x: bounds.midX, y: bounds.midY)
            let target = artboard(at: center, on: pageID)
            if target != layer.parent {
                reparent(id, to: target.map(LayerParent.layer) ?? .page(pageID))
            }
        }
    }

    /// Copies layers (with their contents) right above the originals and returns the copies.
    /// Top-level artboards are placed to the right of the original instead.
    public mutating func duplicate(_ ids: [LayerID]) -> [LayerID] {
        var copies: [LayerID] = []
        for id in document.topmostOnly(ids) {
            guard let parent = document.parentRef(of: id),
                  let index = document.childIDs(of: parent).firstIndex(of: id) else { continue }
            var clipboard = LayerClipboard(copying: [id], from: document)
            if case .page = parent, let layer = document.layers[id], layer.isArtboard {
                clipboard.offset(by: CGVector(dx: layer.frame.width + 100, dy: 0))
            }
            copies += paste(clipboard, into: parent, at: index + 1)
        }
        return copies
    }

    /// Inserts copies of the clipboard's layers (with new IDs) at the same page position.
    @discardableResult
    public mutating func paste(_ clipboard: LayerClipboard, into parent: LayerParent, at index: Int? = nil) -> [LayerID] {
        let contents: CGAffineTransform
        if case .layer(let id) = parent { contents = document.contentsTransform(of: id) } else { contents = .identity }
        var position = index
        var pasted: [LayerID] = []
        for (_, data) in clipboard.images { addImage(data) }
        // Symbols the target document does not have yet arrive with their masters.
        for master in clipboard.masters {
            guard let symbolID = clipboard.layers[master]?.symbolID, document.master(of: symbolID) == nil else { continue }
            let page = symbolsPageID()
            var copy = clipboard.clonedSubtree(of: master)
            guard var top = copy.first else { continue }
            let right = document.page(page).flatMap { document.contentBounds(of: $0) }.map { $0.maxX + 100 } ?? 0
            top.frame.x = right
            top.frame.y = 0
            copy[0] = top
            insert(top, into: .page(page))
            for layer in copy.dropFirst() {
                guard let layerParent = layer.parent else { continue }
                insert(layer, into: .layer(layerParent))
            }
        }

        for root in clipboard.roots {
            let copy = clipboard.clonedSubtree(of: root)
            guard var top = copy.first else { continue }
            let origin = CGPoint(x: top.frame.x, y: top.frame.y).applying(contents.inverted())
            top.frame.x = origin.x
            top.frame.y = origin.y
            insert(top, into: parent, at: position)
            for layer in copy.dropFirst() {
                guard let layerParent = layer.parent else { continue }
                insert(layer, into: .layer(layerParent))
            }
            pasted.append(top.id)
            position = position.map { $0 + 1 }
        }
        return pasted
    }

    /// Path points stretched from `old` to `new` (both frames), mirrored when flipped, with
    /// their bounds starting at 0,0 so the frame stays wrapped around them.
    static func scaled(_ vector: VectorPath, from old: Rect, to new: CGRect, flipX: Bool, flipY: Bool) -> VectorPath {
        let sx = old.width > 0.001 ? new.width / old.width : 1
        let sy = old.height > 0.001 ? new.height / old.height : 1
        let stretched = vector.applying(CGAffineTransform(scaleX: flipX ? -sx : sx, y: flipY ? -sy : sy))
        let bounds = stretched.bounds
        return stretched.applying(CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY))
    }

    public func artboard(at point: CGPoint, on pageID: PageID) -> LayerID? {
        document.artboard(at: point, on: pageID)
    }

    private mutating func setChildren(_ children: [LayerID], of parent: LayerParent) {
        switch parent {
        case .page(let id): updatePage(id) { $0.layers = children }
        case .layer(let id): update(id) { $0.children = children }
        }
    }
}

extension Document {
    /// Whether `ids` may go into `parent`: not into themselves or their contents, artboards and
    /// symbol masters only onto the page, and nothing into symbol instances.
    public func canMove(_ ids: [LayerID], into parent: LayerParent) -> Bool {
        guard case .layer(let target) = parent else { return true }
        guard let container = layers[target], container.isContainer, container.symbolInstance == nil else { return false }
        let path = Set(ancestors(of: target) + [target])
        return ids.allSatisfy { id in !path.contains(id) && layers[id]?.isArtboard == false }
    }
}
