import CoreGraphics
import Foundation

/// Edits of the selected layers, used by commands, menus and panels.
extension DocumentEditor {
    public func deleteSelection() {
        let ids = document.topmostOnly(selection)
        guard !ids.isEmpty else { return }
        perform(ids.count == 1 ? "Delete Layer" : "Delete Layers", select: []) { transaction in
            for id in ids { transaction.remove(id) }
        }
    }

    public func duplicateSelection() {
        performSelecting("Duplicate") { $0.duplicate(selection) }
    }

    /// Everything next to the current selection, or every top-level layer when nothing is selected.
    public func selectAll() {
        if let first = selection.first, let parent = document.parentRef(of: first) {
            select(document.childIDs(of: parent).reversed())
        } else {
            select(page.layers.reversed())
        }
    }

    /// Hides all when any is visible, otherwise shows all.
    public func toggleHidden() {
        let hide = selectedLayers.contains(where: \.isVisible)
        perform(hide ? "Hide" : "Show") { transaction in
            for id in selection { transaction.update(id) { $0.isVisible = !hide } }
        }
    }

    public func toggleLocked() {
        let lock = selectedLayers.contains { !$0.isLocked }
        perform(lock ? "Lock" : "Unlock") { transaction in
            for id in selection { transaction.update(id) { $0.isLocked = lock } }
        }
    }

    public func groupSelection() {
        performSelecting("Group") { transaction in
            transaction.group(selection).map { [$0] } ?? selection
        }
    }

    public func ungroupSelection() {
        performSelecting("Ungroup") { transaction in
            let children = selection.flatMap { transaction.ungroup($0) }
            return children.isEmpty ? selection : children
        }
    }

    // MARK: Vectors

    /// Shapes become editable paths and text becomes letter outlines.
    public func convertSelectionToPaths() {
        performSelecting("Convert to Paths") { transaction in
            let converted = transaction.convertToPaths(selection)
            return converted.isEmpty ? selection : converted
        }
    }

    public func outlineSelectionBorders() {
        performSelecting("Outline Stroke") { transaction in
            let outlines = transaction.outlineBorders(selection)
            return outlines.isEmpty ? selection : outlines
        }
    }

    public func combineSelection(_ operation: BooleanOperation) {
        performSelecting(operation.title) { transaction in
            transaction.combine(selection, operation).map { [$0] } ?? selection
        }
    }

    /// With one layer, turns it into a mask (or back); with several, groups them and masks the
    /// group's contents with the bottom one.
    public func maskSelection() {
        if selection.count == 1, let id = selection.first {
            let isMask = document.layers[id]?.isMask == true
            perform(isMask ? "Remove Mask" : "Use as Mask") { $0.update(id) { $0.isMask = !isMask } }
            return
        }
        performSelecting("Mask") { transaction in
            guard let group = transaction.group(selection, name: "Mask Group"),
                  let bottom = transaction[group]?.children.first else { return selection }
            transaction.update(bottom) { $0.isMask = true }
            return [group]
        }
    }

    // MARK: Layout

    /// Lines the selection up in a new stack, or makes the selected container a stack.
    public func addStack() {
        performSelecting("Add Stack") { transaction in
            transaction.addStack(selection).map { [$0] } ?? selection
        }
    }

    public func removeStack() {
        updateSelection("Remove Stack") { $0.stack = nil }
    }

    public func updateStack(_ actionName: String, coalescingKey: String? = nil, _ body: @escaping (inout StackLayout) -> Void) {
        updateSelection(actionName, coalescingKey: coalescingKey) { layer in
            guard var stack = layer.stack else { return }
            body(&stack)
            layer.stack = stack
        }
    }

    // MARK: Align and distribute

    public func align(_ edge: AlignEdge) {
        perform("Align") { $0.align(selection, edge) }
    }

    public func distribute(horizontally: Bool, spacing: Double? = nil) {
        perform(spacing == nil ? "Distribute" : "Change Spacing") { $0.distribute(selection, horizontally: horizontally, spacing: spacing) }
    }

    /// Drag and drop in the layers list: see `Transaction.move(_:into:at:)`.
    public func moveLayers(_ ids: [LayerID], into parent: LayerParent, at index: Int) {
        performSelecting("Move Layers") { transaction in
            let moved = transaction.move(ids, into: parent, at: index)
            return moved.isEmpty ? selection : moved
        }
    }

    public func reorder(_ direction: ReorderDirection) {
        perform("Arrange") { $0.reorder(selection, direction) }
    }

    /// Moves the selection by page units; repeated nudges merge into one undo step.
    public func nudge(dx: Double, dy: Double) {
        perform("Move", coalescingKey: "nudge") { $0.move(selection, by: CGVector(dx: dx, dy: dy)) }
    }

    public func resizeEdges(dx: Double, dy: Double, fromOpposite: Bool) {
        perform("Resize", coalescingKey: "resize-keys") { transaction in
            transaction.resizeEdges(selection, dx: dx, dy: dy, fromOpposite: fromOpposite)
        }
    }

    public func rename(_ id: LayerID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        perform("Rename") { $0.update(id) { $0.name = trimmed } }
    }

    /// Changes every selected layer; `coalescingKey` merges quick repeated changes (dragging a
    /// color, stepping a value with arrows) into one undo step.
    public func updateSelection(_ actionName: String, coalescingKey: String? = nil, _ body: (inout Layer) -> Void) {
        perform(actionName, coalescingKey: coalescingKey) { transaction in
            for id in selection { transaction.update(id, body) }
        }
    }

    /// Adds a shape of the default size centered on `center` (page coordinates), inside the
    /// artboard there if any, and selects it.
    @discardableResult
    public func insertShape(_ tool: Tool, centeredAt center: CGPoint) -> LayerID? {
        let size = tool.defaultSize
        let parentID = tool == .artboard ? nil : document.artboard(at: center, on: pageID)
        let parent = parentID.map(LayerParent.layer) ?? .page(pageID)
        let space = parentID.map(document.contentsTransform(of:)) ?? .identity
        let local = center.applying(space.inverted())
        let start = CGPoint(x: (local.x - size.width / 2).rounded(), y: (local.y - size.height / 2).rounded())
        guard let layer = tool.makeLayer(from: start, to: CGPoint(x: start.x + size.width, y: start.y + size.height)) else { return nil }
        perform("Add \(tool.title)", select: [layer.id]) { $0.insert(layer, into: parent) }
        return layer.id
    }

    /// Adds an image centered on `center`, inside the artboard there (scaled down to fit it),
    /// and selects it. Returns nil when the bytes are not an image.
    @discardableResult
    public func insertImage(_ data: Data, named name: String, centeredAt center: CGPoint) -> LayerID? {
        guard var size = ImageData.naturalSize(of: data), size.width > 0, size.height > 0 else { return nil }
        let parentID = document.artboard(at: center, on: pageID)
        if let parentID, let artboard = document.layers[parentID] {
            let scale = min(1, artboard.frame.width * 0.9 / size.width, artboard.frame.height * 0.9 / size.height)
            size = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        }
        let space = parentID.map(document.contentsTransform(of:)) ?? .identity
        let local = center.applying(space.inverted())
        let frame = Rect(x: (local.x - size.width / 2).rounded(), y: (local.y - size.height / 2).rounded(), width: size.width, height: size.height)
        var layerID: LayerID?
        perform("Add Image") { transaction in
            let hash = transaction.addImage(data)
            let layer = Layer(name: name, kind: .image(hash: hash), frame: frame)
            transaction.insert(layer, into: parentID.map(LayerParent.layer) ?? .page(pageID))
            layerID = layer.id
        }
        if let layerID { select([layerID]) }
        return layerID
    }

    /// Adds imported layers (an SVG, for example) centered on `center`, inside the artboard there.
    @discardableResult
    public func insertImported(_ clipboard: LayerClipboard, centeredAt center: CGPoint, actionName: String = "Import") -> [LayerID] {
        var clipboard = clipboard
        let frames = clipboard.roots.compactMap { clipboard.layers[$0]?.frame.cgRect }
        guard let first = frames.first else { return [] }
        let bounds = frames.dropFirst().reduce(first) { $0.union($1) }
        // The top-left corner lands on a whole point, even when the imported bounds are fractional.
        clipboard.offset(by: CGVector(dx: (center.x - bounds.width / 2).rounded() - bounds.minX,
                                      dy: (center.y - bounds.height / 2).rounded() - bounds.minY))
        let parent = document.artboard(at: center, on: pageID).map(LayerParent.layer) ?? .page(pageID)
        var inserted: [LayerID] = []
        performSelecting(actionName) { transaction in
            inserted = transaction.paste(clipboard, into: parent)
            return inserted
        }
        return inserted
    }

    // MARK: Pages

    public func addPage() {
        var newPage: PageID?
        perform("Add Page") { transaction in
            newPage = transaction.addPage(named: transaction.document.nextPageName(), after: pageID)
        }
        if let newPage { showPage(newPage) }
    }

    public func removeCurrentPage() {
        guard document.pages.count > 1 else { return }
        let removed = pageID
        perform("Delete Page", select: []) { $0.removePage(removed) }
    }

    public func renamePage(_ id: PageID, to name: String) {
        perform("Rename Page") { $0.renamePage(id, to: name) }
    }

    /// Shows the next (or previous) page, wrapping around.
    public func showAdjacentPage(forward: Bool) {
        guard let index = document.pages.firstIndex(where: { $0.id == pageID }), document.pages.count > 1 else { return }
        let count = document.pages.count
        showPage(document.pages[(index + (forward ? 1 : -1) + count) % count].id)
    }

    /// Moves the selection to another page and follows it there.
    public func moveSelection(toPage target: PageID) {
        let ids = selection
        guard !ids.isEmpty, target != pageID else { return }
        perform("Move to Page", select: []) { $0.move(ids, toPage: target) }
        showPage(target)
        select(ids)
    }

    /// Pastes into the selected artboard, next to the selected layer, or onto the page.
    public func paste(_ clipboard: LayerClipboard) {
        var parent: LayerParent = .page(pageID)
        var index: Int?
        if let first = selection.first, let layer = document.layers[first] {
            let pastesArtboards = clipboard.roots.contains { clipboard.layers[$0]?.isArtboard == true }
            if layer.isArtboard, !pastesArtboards {
                parent = .layer(first)
            } else if let selectedParent = document.parentRef(of: first) {
                parent = selectedParent
                index = document.childIDs(of: selectedParent).firstIndex(of: first).map { $0 + 1 }
            }
        }
        performSelecting("Paste") { $0.paste(clipboard, into: parent, at: index) }
    }
}
