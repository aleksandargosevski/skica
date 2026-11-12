import AppKit
import SkicaCore

/// A path being drawn with the pen: click adds a corner, click-drag a smooth point, clicking the
/// first point closes it, ↩ or esc finishes it open. The whole path is one undo step.
///
/// As in Illustrator and Figma, clicking the last point again removes its outgoing handle, so the
/// next segment starts straight; dragging from it (or ⌥-dragging a new point) pulls out only the
/// outgoing handle, for a sharp turn between two curves.
struct PenSession {
    let layerID: LayerID
    let parent: LayerParent
    /// Page coordinates.
    var points: [PathPoint]
    /// Where the next point would go (the pointer), for the preview segment.
    var preview: CGPoint?
    var isDragging = false
    /// The drag moves only the outgoing handle and leaves the incoming one where it is.
    var dragsOutHandleOnly = false
}

/// Editing the points of one path layer.
struct PathEditState {
    enum Drag {
        /// `layer` is the layer as it was when the drag started; all moves are relative to it.
        case points(start: CGPoint, layer: Layer)
        case handle(PointRef, out: Bool, layer: Layer)
    }

    let layerID: LayerID
    var selected: Set<PointRef> = []
    var drag: Drag?
}

extension CanvasView {
    // MARK: Pen

    func penMouseDown(at point: CGPoint, modifiers: NSEvent.ModifierFlags) {
        var world = viewport.toCanvas(point).rounded
        if var session = penSession {
            if let last = session.points.last?.point, modifiers.contains(.shift) { world = Self.constrained(world, from: last) }
            if session.points.count >= 2, let first = session.points.first?.point,
               hypot(viewport.toView(first).x - point.x, viewport.toView(first).y - point.y) < 8 {
                return finishPen(closed: true)
            }
            if let last = session.points.indices.last,
               hypot(viewport.toView(session.points[last].point).x - point.x, viewport.toView(session.points[last].point).y - point.y) < 8 {
                // Clicking the last point again: the next segment leaves it straight.
                session.points[last].curveOut = nil
                session.points[last].mode = session.points[last].curveIn == nil ? .straight : .disconnected
                session.isDragging = true
                session.dragsOutHandleOnly = true
                penSession = session
                return updatePenLayer()
            }
            session.points.append(PathPoint(world))
            session.isDragging = true
            session.dragsOutHandleOnly = false
            penSession = session
        } else {
            let parentID = editor.document.artboard(at: world, on: editor.pageID)
            penSession = PenSession(layerID: .make(), parent: parentID.map(LayerParent.layer) ?? .page(editor.pageID),
                                    points: [PathPoint(world)], isDragging: true)
            editor.beginLiveEdit()
        }
        updatePenLayer()
    }

    /// Dragging after a click pulls out the new point's handles: both, mirrored, or with ⌥ (or
    /// when dragging from the last point again) only the outgoing one.
    func penMouseDragged(to point: CGPoint, modifiers: NSEvent.ModifierFlags) {
        guard var session = penSession, session.isDragging, let last = session.points.indices.last else { return }
        let world = viewport.toCanvas(point).rounded
        let anchor = session.points[last].point
        guard hypot(world.x - anchor.x, world.y - anchor.y) > 2 else { return }
        session.points[last].curveOut = world
        if session.dragsOutHandleOnly || modifiers.contains(.option) {
            session.points[last].mode = .disconnected
        } else {
            session.points[last].curveIn = CGPoint(x: 2 * anchor.x - world.x, y: 2 * anchor.y - world.y)
            session.points[last].mode = .mirrored
        }
        penSession = session
        updatePenLayer()
    }

    func penMouseUp() {
        penSession?.isDragging = false
    }

    func penMouseMoved(to point: CGPoint, modifiers: NSEvent.ModifierFlags) {
        guard var session = penSession else { return }
        var world = viewport.toCanvas(point).rounded
        if let last = session.points.last?.point, modifiers.contains(.shift) { world = Self.constrained(world, from: last) }
        session.preview = world
        penSession = session
    }

    /// Ends drawing; paths with fewer than two points are dropped.
    func finishPen(closed: Bool) {
        guard let session = penSession else { return }
        if session.points.count < 2 {
            penSession = nil
            editor.cancelLiveEdit()
        } else {
            updatePenLayer(closed: closed)
            penSession = nil
            editor.endLiveEdit("Add Path")
        }
        if editor.tool == .pen { editor.tool = .select }
    }

    func removeLastPenPoint() {
        guard var session = penSession else { return }
        session.points.removeLast()
        if session.points.isEmpty {
            penSession = nil
            editor.cancelLiveEdit()
            return
        }
        penSession = session
        updatePenLayer()
    }

    private func updatePenLayer(closed: Bool = false) {
        guard let session = penSession else { return }
        let space: CGAffineTransform
        if case .layer(let parentID) = session.parent { space = editor.document.contentsTransform(of: parentID).inverted() } else { space = .identity }
        let points = session.points.map { $0.applying(space) }
        let vector = VectorPath(subpaths: [Subpath(points: points, isClosed: closed)])
        let layer = Layer(id: session.layerID, name: "Path", kind: .path(vector), frame: Rect(x: 0, y: 0, width: 0, height: 0),
                          style: Style(borders: [Border(.black, width: 1)]))
        editor.updateLiveEdit(select: [session.layerID]) { $0.insert(layer, into: session.parent) }
    }

    /// Snaps a point to the nearest 45° direction from `origin`.
    static func constrained(_ point: CGPoint, from origin: CGPoint) -> CGPoint {
        let dx = point.x - origin.x
        let dy = point.y - origin.y
        let angle = (atan2(dy, dx) / (.pi / 4)).rounded() * (.pi / 4)
        let length = hypot(dx, dy)
        return CGPoint(x: (origin.x + cos(angle) * length).rounded(), y: (origin.y + sin(angle) * length).rounded())
    }

    // MARK: Editing points

    /// Starts editing the points of a layer, turning a shape into a path first.
    func beginPathEditing(_ id: LayerID) {
        guard let layer = editor.document.layers[id] else { return }
        if layer.vectorPath == nil {
            switch layer.kind {
            case .rectangle, .oval, .line, .polygon, .star:
                editor.performSelecting("Convert to Path") { $0.convertToPaths([id]) }
            default:
                return NSSound.beep()
            }
        }
        guard editor.document.layers[id]?.vectorPath != nil else { return }
        endTextEditing()
        editor.select([id])
        pathEdit = PathEditState(layerID: id)
    }

    func endPathEditing() {
        guard pathEdit != nil else { return }
        if editor.isLiveEditing { editor.endLiveEdit("Edit Points") }
        pathEdit = nil
    }

    /// Returns false when the click is away from the path, which ends editing.
    func pathMouseDown(at point: CGPoint, modifiers: NSEvent.ModifierFlags) -> Bool {
        guard var edit = pathEdit, let layer = editor.document.layers[edit.layerID], let vector = layer.vectorPath else {
            pathEdit = nil
            return false
        }
        let world = viewport.toCanvas(point)
        let reach: CGFloat = 7

        for ref in edit.selected.sorted() {
            guard let pathPoint = vector[ref] else { continue }
            for (out, handle) in [(false, pathPoint.curveIn), (true, pathPoint.curveOut)] {
                guard let handle, distance(viewport.toView(pagePoint(handle, of: layer)), point) < reach else { continue }
                edit.drag = .handle(ref, out: out, layer: layer)
                pathEdit = edit
                editor.beginLiveEdit()
                return true
            }
        }
        if let ref = vector.pointRefs.min(by: { distance(viewport.toView(pagePoint(vector[$0]!.point, of: layer)), point) < distance(viewport.toView(pagePoint(vector[$1]!.point, of: layer)), point) }),
           distance(viewport.toView(pagePoint(vector[ref]!.point, of: layer)), point) < reach {
            if modifiers.contains(.shift) {
                if edit.selected.contains(ref) { edit.selected.remove(ref) } else { edit.selected.insert(ref) }
            } else if !edit.selected.contains(ref) {
                edit.selected = [ref]
            }
            edit.drag = .points(start: world, layer: layer)
            pathEdit = edit
            editor.beginLiveEdit()
            return true
        }
        let local = localPoint(world, of: layer)
        if let hit = vector.segment(near: local, tolerance: 5 / viewport.zoom) {
            var inserted: PointRef?
            editor.perform("Add Point") { transaction in
                transaction.update(edit.layerID) { layer in
                    guard var vector = layer.vectorPath else { return }
                    inserted = vector.insertPoint(on: hit.start, at: hit.t)
                    layer.kind = .path(vector)
                }
            }
            edit.selected = inserted.map { [$0] } ?? []
            pathEdit = edit
            return true
        }
        let area = (editor.document.worldBounds(of: edit.layerID) ?? .zero).insetBy(dx: -20 / viewport.zoom, dy: -20 / viewport.zoom)
        guard area.contains(world) else {
            pathEdit = nil
            return false
        }
        edit.selected = []
        pathEdit = edit
        return true
    }

    func pathMouseDragged(to point: CGPoint) {
        guard let edit = pathEdit, let drag = edit.drag else { return }
        let world = viewport.toCanvas(point)
        switch drag {
        case .points(let start, let layer):
            guard var vector = layer.vectorPath else { return }
            let from = localPoint(start, of: layer)
            let to = localPoint(world, of: layer)
            let delta = CGAffineTransform(translationX: (to.x - from.x).rounded(), y: (to.y - from.y).rounded())
            for ref in edit.selected { vector[ref] = vector[ref]?.applying(delta) }
            editor.updateLiveEdit { $0.update(edit.layerID) { $0.kind = .path(vector) } }
        case .handle(let ref, let out, let layer):
            guard var vector = layer.vectorPath, var pathPoint = vector[ref] else { return }
            pathPoint.setHandle(out: out, to: localPoint(world, of: layer))
            vector[ref] = pathPoint
            editor.updateLiveEdit { $0.update(edit.layerID) { $0.kind = .path(vector) } }
        }
    }

    func pathMouseUp() {
        guard pathEdit?.drag != nil else { return }
        pathEdit?.drag = nil
        editor.endLiveEdit("Edit Points")
    }

    /// Keys while editing points; returns false for keys that are not about points.
    func handlePathKey(_ chord: KeyChord) -> Bool {
        guard var edit = pathEdit, let layer = editor.document.layers[edit.layerID], let vector = layer.vectorPath else { return false }
        let refs = vector.pointRefs
        switch (chord.key, chord.modifiers) {
        case ("esc", []), ("enter", []):
            endPathEditing()
        case ("tab", let modifiers) where modifiers.isSubset(of: [.shift]):
            guard !refs.isEmpty else { return true }
            let forward = !modifiers.contains(.shift)
            let current = forward ? edit.selected.max() : edit.selected.min()
            let index = current.flatMap(refs.firstIndex(of:)).map { forward ? ($0 + 1) % refs.count : ($0 - 1 + refs.count) % refs.count }
                ?? (forward ? 0 : refs.count - 1)
            edit.selected = [refs[index]]
            pathEdit = edit
        case ("a", [.command]):
            edit.selected = Set(refs)
            pathEdit = edit
        case ("1", []), ("2", []), ("3", []), ("4", []):
            let mode: PathPoint.Mode = ["1": .straight, "2": .mirrored, "3": .asymmetric, "4": .disconnected][chord.key]!
            updatePoints(edit, "Change Point Type") { vector, ref in
                let neighbors = vector.neighbors(of: ref)
                vector[ref]?.setMode(mode, previous: neighbors.previous, next: neighbors.next)
            }
        case ("backspace", []), ("delete", []):
            guard !edit.selected.isEmpty else { return true }
            var remaining = vector
            remaining.removePoints(edit.selected)
            if remaining.isEmpty {
                pathEdit = nil
                editor.perform("Delete Path", select: []) { $0.remove(edit.layerID) }
            } else {
                editor.perform("Delete Points") { $0.update(edit.layerID) { $0.kind = .path(remaining) } }
                edit.selected = []
                pathEdit = edit
            }
        case ("left", let modifiers), ("right", let modifiers), ("up", let modifiers), ("down", let modifiers):
            guard modifiers.isSubset(of: [.shift]), !edit.selected.isEmpty else { return modifiers.isSubset(of: [.shift]) }
            let step: CGFloat = modifiers.contains(.shift) ? 10 : 1
            let direction: CGVector = ["left": CGVector(dx: -1, dy: 0), "right": CGVector(dx: 1, dy: 0), "up": CGVector(dx: 0, dy: -1), "down": CGVector(dx: 0, dy: 1)][chord.key]!
            let start = pagePoint(.zero, of: layer)
            let moved = localPoint(CGPoint(x: start.x + direction.dx * step, y: start.y + direction.dy * step), of: layer)
            let delta = CGAffineTransform(translationX: moved.x, y: moved.y)
            updatePoints(edit, "Move Points", coalescingKey: "points-\(edit.layerID)") { vector, ref in
                vector[ref] = vector[ref]?.applying(delta)
            }
        default:
            return false
        }
        return true
    }

    private func updatePoints(_ edit: PathEditState, _ actionName: String, coalescingKey: String? = nil, _ body: @escaping (inout VectorPath, PointRef) -> Void) {
        editor.perform(actionName, coalescingKey: coalescingKey) { transaction in
            transaction.update(edit.layerID) { layer in
                guard var vector = layer.vectorPath else { return }
                for ref in edit.selected { body(&vector, ref) }
                layer.kind = .path(vector)
            }
        }
    }

    // MARK: Coordinates

    /// A point of a path (in the layer's own coordinates) on the page.
    func pagePoint(_ local: CGPoint, of layer: Layer) -> CGPoint {
        CGPoint(x: local.x + layer.frame.x, y: local.y + layer.frame.y).applying(worldTransform(of: layer))
    }

    func localPoint(_ page: CGPoint, of layer: Layer) -> CGPoint {
        let parent = page.applying(worldTransform(of: layer).inverted())
        return CGPoint(x: parent.x - layer.frame.x, y: parent.y - layer.frame.y)
    }

    /// Computed from the given layer value rather than the document, so drags can use the layer
    /// as it was when they started.
    private func worldTransform(of layer: Layer) -> CGAffineTransform {
        layer.rotationTransform.concatenating(editor.document.parentSpace(of: layer.id))
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }
}
