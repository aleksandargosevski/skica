import AppKit
import SkicaCore
import SkicaRender

/// The infinite canvas of the current page. The document and the selection overlay are drawn
/// in separate layers, so hovering and selecting never repaint the document.
final class CanvasView: NSView {
    let editor: DocumentEditor
    let state: EditorState
    var isSpaceHeld = false {
        didSet { if isSpaceHeld != oldValue { updateCursor() } }
    }

    private(set) var viewport = Viewport() {
        didSet {
            state.zoom = viewport.zoom
            contentLayer.needsDisplay = true
            overlayLayer.needsDisplay = true
            textSession?.layout(viewport: viewport)
        }
    }
    /// The layer under the pointer that a click would select.
    private(set) var hovered: LayerID? {
        didSet { if hovered != oldValue { overlayLayer.needsDisplay = true } }
    }
    private(set) var interaction: CanvasInteraction = .idle {
        didSet { overlayLayer.needsDisplay = true }
    }

    private var renderer = CanvasRenderer(options: RenderOptions(showsArtboardShadows: true))
    /// The text layer being typed into, if any.
    private(set) var textSession: TextEditingSession?
    /// A path being drawn with the pen tool.
    var penSession: PenSession? {
        didSet {
            overlayLayer.needsDisplay = true
            updateModeLine()
        }
    }
    /// The path whose points are being edited.
    var pathEdit: PathEditState? {
        didSet {
            overlayLayer.needsDisplay = true
            updateModeLine()
        }
    }

    /// The image being cropped.
    var cropEdit: CropEditState? {
        didSet {
            if cropEdit?.layerID != oldValue?.layerID {
                renderer.options.revealedCrop = cropEdit?.layerID
                contentLayer.needsDisplay = true
            }
            overlayLayer.needsDisplay = true
            updateModeLine()
        }
    }

    var isEditingVectors: Bool { penSession != nil || pathEdit != nil }

    private func updateModeLine() {
        if penSession != nil {
            state.mode = "Pen"
            state.modeHint = "click: corner   drag: curve   click last point: next segment straight   ⌥-drag: sharp turn   click first point: close   ↩ finish   ⌫ undo point"
        } else if cropEdit != nil {
            state.mode = "Crop"
            state.modeHint = "drag edges: crop   drag inside: move the image   arrows: nudge it (⇧ ×10)   esc or ↩ done"
        } else if let edit = pathEdit {
            state.mode = "Edit Points"
            let count = edit.selected.count
            state.modeHint = "\(count) selected   ⇥ next   1 straight  2 mirrored  3 asymmetric  4 disconnected   ⌫ delete   esc done"
        } else {
            state.mode = nil
            state.modeHint = nil
        }
    }
    private lazy var contentLayer = CanvasLayerView(isOpaque: true) { [unowned self] in drawContent($0) }
    private lazy var overlayLayer = CanvasLayerView(isOpaque: false) { [unowned self] in drawOverlay($0) }
    /// Edges and centers to snap to during the current drag, and the guides currently shown.
    private var snapper: Snapper?
    private var guides: [SnapGuide] = [] {
        didSet { if guides != oldValue { overlayLayer.needsDisplay = true } }
    }
    private var hasPlacedViewport = false
    private var pageViewports: [PageID: Viewport] = [:]
    private var shownPage: PageID?
    private(set) var lastMouse: CGPoint?

    /// View points the pointer must travel before a press becomes a drag.
    private static let dragThreshold: CGFloat = 3

    init(editor: DocumentEditor, state: EditorState) {
        self.editor = editor
        self.state = state
        self.shownPage = editor.pageID
        super.init(frame: .zero)
        wantsLayer = true
        for layerView in [contentLayer, overlayLayer] {
            layerView.frame = bounds
            layerView.autoresizingMask = [.width, .height]
            addSubview(layerView)
        }
        editor.observe { [weak self] change in self?.editorChanged(change) }
        registerForDraggedTypes(ImageImport.draggedTypes)
    }

    // MARK: Drag and drop

    /// Called with image files (or image data) dropped at a page point.
    var onDropImages: ((_ files: [URL], _ data: Data?, _ point: CGPoint) -> Void)?

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        ImageImport.hasImage(on: sender.draggingPasteboard) ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pasteboard = sender.draggingPasteboard
        let point = viewport.toCanvas(convert(sender.draggingLocation, from: nil))
        let files = ImageImport.imageFiles(on: pasteboard)
        let data = files.isEmpty ? ImageImport.imageData(from: pasteboard) : nil
        guard !files.isEmpty || data != nil || ImageImport.svgData(from: pasteboard) != nil else { return false }
        onDropImages?(files, data, point)
        return true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    // MARK: Viewport

    var visibleCenter: CGPoint { viewport.toCanvas(CGPoint(x: bounds.midX, y: bounds.midY)) }

    func zoomStep(up: Bool) {
        let target = up ? Viewport.step(above: viewport.zoom) : Viewport.step(below: viewport.zoom)
        viewport.setZoom(target, keeping: CGPoint(x: bounds.midX, y: bounds.midY))
    }

    func zoomToActualSize() {
        viewport.setZoom(1, keeping: CGPoint(x: bounds.midX, y: bounds.midY))
    }

    /// Fits everything on the page; an empty page is centered on the canvas origin.
    func zoomToFit(maxZoom: CGFloat = Viewport.zoomRange.upperBound) {
        guard let content = editor.document.contentBounds(of: editor.page) else {
            viewport = Viewport()
            viewport.center(on: .zero, in: bounds.size)
            return
        }
        viewport.fit(content, in: bounds.size, maxZoom: maxZoom)
    }

    func zoomToSelection() {
        guard let box = editor.document.worldBounds(of: editor.selection) else { return zoomToFit() }
        viewport.fit(box, in: bounds.size, padding: 64)
    }

    func panByKeyboard(dx: CGFloat, dy: CGFloat) {
        viewport.pan(by: CGVector(dx: dx, dy: dy))
    }

    /// Scrolls the selection into view when it is entirely off-screen.
    func revealSelection() {
        guard let box = editor.document.worldBounds(of: editor.selection) else { return }
        let visible = viewport.toCanvas(bounds)
        if !visible.intersects(box) {
            viewport.center(on: CGPoint(x: box.midX, y: box.midY), in: bounds.size)
        }
    }

    // MARK: Hints

    /// Labels shown by `f`: typing one selects (or with `adding`, adds) its layer.
    struct Hints {
        var labels: [(label: String, id: LayerID)]
        var typed = ""
        var adding: Bool
    }

    private(set) var hints: Hints? {
        didSet { overlayLayer.needsDisplay = true }
    }

    var isHinting: Bool { hints != nil }

    func beginHints(adding: Bool) {
        let area = viewport.toCanvas(bounds)
        let targets = HintLabels.targets(on: editor.page, in: editor.document, selection: editor.selection, area: area)
        guard !targets.isEmpty else { return NSSound.beep() }
        hints = Hints(labels: Array(zip(HintLabels.labels(count: targets.count), targets)).map { ($0.0, $0.1) }, adding: adding)
    }

    func cancelHints() {
        hints = nil
    }

    /// Narrows the labels by a typed letter; a complete label picks its layer and ends hinting.
    func typeHint(_ letter: String) {
        guard var current = hints else { return }
        current.typed += letter.lowercased()
        let matches = current.labels.filter { $0.label.hasPrefix(current.typed) }
        if let exact = matches.first(where: { $0.label == current.typed }) {
            hints = nil
            editor.select(current.adding ? editor.selection.filter { $0 != exact.id } + [exact.id] : [exact.id])
            revealSelection()
        } else if matches.isEmpty {
            hints = nil
            NSSound.beep()
        } else {
            hints = current
        }
    }

    func deleteHintLetter() {
        guard var current = hints, !current.typed.isEmpty else { return }
        current.typed.removeLast()
        hints = current
    }

    // MARK: Text editing

    /// Starts typing into a text layer; `caretAt` (a view point) places the caret, otherwise all
    /// text is selected.
    func beginTextEditing(_ id: LayerID, caretAt point: CGPoint? = nil) {
        guard editor.document.layers[id]?.textContent != nil else { return }
        endTextEditing()
        editor.select([id])
        let session = TextEditingSession(layerID: id, editor: editor, in: self)
        textSession = session
        renderer.options.hiddenLayer = id
        contentLayer.needsDisplay = true
        session.layout(viewport: viewport)
        window?.makeFirstResponder(session.textView)
        if let point { session.placeCaret(at: point) } else { session.selectAll() }
    }

    /// Stops typing; text left empty is removed, as in Sketch.
    func endTextEditing() {
        guard let session = textSession else { return }
        textSession = nil
        session.end()
        renderer.options.hiddenLayer = nil
        contentLayer.needsDisplay = true
        if editor.document.layers[session.layerID]?.textContent?.string.isEmpty == true {
            editor.perform("Delete Empty Text", select: []) { $0.remove(session.layerID) }
        }
        if window?.firstResponder === session.textView { window?.makeFirstResponder(self) }
    }

    /// Stops a drag in progress and undoes what it did so far.
    @discardableResult
    func cancelInteraction() -> Bool {
        guard interaction.isActive else { return false }
        if editor.isLiveEditing { editor.cancelLiveEdit() }
        interaction = .idle
        snapper = nil
        guides = []
        return true
    }

    private func editorChanged(_ change: DocumentEditor.Change) {
        switch change {
        case .document:
            contentLayer.needsDisplay = true
            overlayLayer.needsDisplay = true
            if let hovered, editor.document.layers[hovered] == nil { self.hovered = nil }
            if let edit = pathEdit, editor.document.layers[edit.layerID]?.vectorPath == nil, !editor.isLiveEditing {
                pathEdit = nil
            }
            if let crop = cropEdit, editor.document.layers[crop.layerID]?.imageHash == nil, !editor.isLiveEditing {
                cropEdit = nil
            }
            if let textSession {
                if editor.document.layers[textSession.layerID]?.textContent == nil {
                    endTextEditing()
                } else {
                    textSession.reloadFromDocument()
                    textSession.layout(viewport: viewport)
                }
            }
        case .selection:
            overlayLayer.needsDisplay = true
            if let edit = pathEdit, editor.selection != [edit.layerID] { endPathEditing() }
            if let crop = cropEdit, editor.selection != [crop.layerID] { endCropping() }
        case .tool:
            hovered = nil
            if penSession != nil, editor.tool != .pen { finishPen(closed: false) }
            if editor.tool != .select {
                endPathEditing()
                endCropping()
            }
            updateCursor()
        case .page:
            hints = nil
            if penSession != nil { finishPen(closed: false) }
            endPathEditing()
            endCropping()
            endTextEditing()
            showCurrentPage()
        }
    }

    /// Remembers where each page was looked at, and fits pages seen for the first time.
    private func showCurrentPage() {
        if let shownPage { pageViewports[shownPage] = viewport }
        shownPage = editor.pageID
        hovered = nil
        _ = cancelInteraction()
        if let saved = pageViewports[editor.pageID] {
            viewport = saved
        } else {
            zoomToFit(maxZoom: 1)
        }
    }

    /// Fits the page on the first layout of the visible window, when the restored window size
    /// and the panels are known.
    override func layout() {
        super.layout()
        guard !hasPlacedViewport, window?.isVisible == true, bounds.width > 0, bounds.height > 0 else { return }
        hasPlacedViewport = true
        zoomToFit(maxZoom: 1)
    }

    // MARK: Drawing

    private func drawContent(_ dirtyRect: CGRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        NSColor.skicaCanvas.setFill()
        dirtyRect.fill()
        context.saveGState()
        context.scaleBy(x: viewport.zoom, y: viewport.zoom)
        context.translateBy(x: -viewport.origin.x, y: -viewport.origin.y)
        renderer.draw(page: editor.page, of: editor.document, in: context, visibleRect: viewport.toCanvas(dirtyRect))
        context.restoreGState()
    }

    private func drawOverlay(_ dirtyRect: CGRect) {
        CanvasOverlay(
            document: editor.document,
            page: editor.page,
            selection: editor.selection,
            hovered: interaction.isActive ? nil : hovered,
            viewport: viewport,
            marquee: interaction.marqueeRect,
            showsHandles: !interaction.hidesHandles,
            guides: guides,
            hints: hints.map { hints in hints.labels.map { (label: $0.label, id: $0.id, typed: hints.typed) } } ?? [],
            pen: penSession,
            pathEdit: pathEdit,
            crop: cropEdit.flatMap(cropRects)
        ).draw()
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        let point = location(of: event)
        trackPointer(point)
        if penSession != nil { return penMouseMoved(to: point, modifiers: event.modifierFlags) }
        hovered = editor.tool == .select && !isSpaceHeld ? clickTarget(at: point, deep: event.modifierFlags.contains(.command)) : nil
    }

    override func mouseExited(with event: NSEvent) {
        state.cursor = nil
        lastMouse = nil
        hovered = nil
    }

    override func mouseDown(with event: NSEvent) {
        hints = nil
        endTextEditing()
        window?.makeFirstResponder(self)
        let point = location(of: event)
        if !isSpaceHeld, pathEdit != nil, pathMouseDown(at: point, modifiers: event.modifierFlags) { return }
        if !isSpaceHeld, cropEdit != nil, cropMouseDown(at: point) { return }
        if isSpaceHeld {
            interaction = .panning(mouse: point, origin: viewport.origin)
        } else if editor.tool == .pen {
            penMouseDown(at: point, modifiers: event.modifierFlags)
        } else if editor.tool == .select {
            selectMouseDown(at: point, modifiers: event.modifierFlags, clickCount: event.clickCount)
        } else {
            beginCreating(editor.tool, at: point)
        }
        updateCursor()
    }

    override func mouseDragged(with event: NSEvent) {
        let point = location(of: event)
        trackPointer(point)
        if penSession?.isDragging == true { return penMouseDragged(to: point, modifiers: event.modifierFlags) }
        if pathEdit?.drag != nil { return pathMouseDragged(to: point) }
        if cropEdit?.drag != nil { return cropMouseDragged(to: point, modifiers: event.modifierFlags) }
        let modifiers = event.modifierFlags
        let world = viewport.toCanvas(point)

        switch interaction {
        case .idle:
            break
        case .panning(let mouse, let origin):
            viewport.origin = origin
            viewport.pan(by: CGVector(dx: point.x - mouse.x, dy: point.y - mouse.y))
        case .pressing(let start, let startView, _):
            guard hypot(point.x - startView.x, point.y - startView.y) > Self.dragThreshold,
                  let box = editor.document.worldBounds(of: editor.selection) else { return }
            editor.beginLiveEdit()
            prepareSnapping(for: editor.selection)
            interaction = .moving(start: start, box: box)
            updateMove(from: start, box: box, to: world, modifiers: modifiers)
        case .moving(let start, let box):
            updateMove(from: start, box: box, to: world, modifiers: modifiers)
        case .resizing(let handle, let box, let start):
            let keepAspect = modifiers.contains(.shift)
            let fromCenter = modifiers.contains(.option)
            var newBox = SelectionHandle.resizedBox(box, handle: handle, by: CGVector(dx: (world.x - start.x).rounded(), dy: (world.y - start.y).rounded()),
                                                    keepAspect: keepAspect, fromCenter: fromCenter)
            guides = []
            if let snapper, !keepAspect, !fromCenter, !modifiers.contains(.control), newBox.size.width > 0, newBox.size.height > 0 {
                (newBox, guides) = snapper.snap(edgesOf: newBox, movingX: handle.edges.x, movingY: handle.edges.y)
            }
            editor.updateLiveEdit { $0.resize(self.editor.selection, from: box, to: newBox) }
        case .creating(var creation):
            creation.dragged = creation.dragged || hypot(point.x - creation.startView.x, point.y - creation.startView.y) > Self.dragThreshold
            interaction = .creating(creation)
            var end = world
            guides = []
            if let snapper, !modifiers.contains(.control), !modifiers.contains(.shift) {
                (end, guides) = snapper.snap(point: world)
            }
            updateCreation(creation, to: end, square: modifiers.contains(.shift), fromCenter: modifiers.contains(.option))
        case .marquee(let start, _, let base):
            interaction = .marquee(start: start, current: world, base: base)
            let rect = CGRect(x: min(start.x, world.x), y: min(start.y, world.y), width: abs(world.x - start.x), height: abs(world.y - start.y))
            editor.select(base + SelectionRules.marquee(rect, on: editor.page, in: editor.document))
        }
    }

    override func mouseUp(with event: NSEvent) {
        if penSession != nil { return penMouseUp() }
        if pathEdit?.drag != nil { return pathMouseUp() }
        if cropEdit?.drag != nil { return cropMouseUp() }
        switch interaction {
        case .pressing(_, _, let target):
            // A click on a layer of a multiple selection selects just that layer.
            if editor.selection.count > 1, let target { editor.select([target]) }
        case .moving:
            editor.endLiveEdit("Move")
        case .resizing:
            editor.endLiveEdit("Resize")
        case .creating(let creation):
            if !creation.dragged {
                let size = creation.tool.defaultSize
                updateCreation(creation, to: CGPoint(x: creation.start.x + size.width, y: creation.start.y + size.height), square: false, fromCenter: false)
            }
            editor.endLiveEdit("Add \(creation.tool.title)")
            editor.tool = .select
            if creation.tool == .text { beginTextEditing(creation.layerID) }
        case .idle, .panning, .marquee:
            break
        }
        interaction = .idle
        snapper = nil
        guides = []
        updateCursor()
    }

    override func otherMouseDown(with event: NSEvent) {
        interaction = .panning(mouse: location(of: event), origin: viewport.origin)
    }

    override func otherMouseDragged(with event: NSEvent) {
        mouseDragged(with: event)
    }

    override func otherMouseUp(with event: NSEvent) {
        interaction = .idle
    }

    /// Two-finger scroll and the mouse wheel pan; with ⌘ (or ⌥) they zoom around the pointer.
    override func scrollWheel(with event: NSEvent) {
        let point = location(of: event)
        let precise = event.hasPreciseScrollingDeltas
        if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.option) {
            let delta = precise ? event.scrollingDeltaY : event.scrollingDeltaY * 10
            viewport.setZoom(viewport.zoom * exp(delta * 0.01), keeping: point)
        } else {
            let scale: CGFloat = precise ? 1 : 16
            var dx = event.scrollingDeltaX * scale
            var dy = event.scrollingDeltaY * scale
            // A plain mouse wheel with shift scrolls sideways.
            if !precise, event.modifierFlags.contains(.shift), dx == 0 { (dx, dy) = (dy, 0) }
            viewport.pan(by: CGVector(dx: dx, dy: dy))
        }
        trackPointer(point)
    }

    override func magnify(with event: NSEvent) {
        viewport.setZoom(viewport.zoom * (1 + event.magnification), keeping: location(of: event))
    }

    /// Double-tap with two fingers switches between 100% and fitting the page.
    override func smartMagnify(with event: NSEvent) {
        if abs(viewport.zoom - 1) < 0.001 {
            zoomToFit()
        } else {
            viewport.setZoom(1, keeping: location(of: event))
        }
    }

    // MARK: Interactions

    private func selectMouseDown(at point: CGPoint, modifiers: NSEvent.ModifierFlags, clickCount: Int) {
        let world = viewport.toCanvas(point)
        if let handle = handle(at: point), let box = editor.document.worldBounds(of: editor.selection) {
            editor.beginLiveEdit()
            prepareSnapping(for: editor.selection)
            interaction = .resizing(handle: handle, box: box, start: world)
            return
        }

        let target = clickCount == 2
            ? doubleClickTarget(at: point)
            : clickTarget(at: point, deep: modifiers.contains(.command))
        if clickCount == 2, let target, editor.document.layers[target]?.textContent != nil {
            beginTextEditing(target, caretAt: point)
            return
        }
        if clickCount == 2, let target, editor.document.layers[target]?.vectorPath != nil {
            beginPathEditing(target)
            return
        }
        if clickCount == 2, let target, editor.document.layers[target]?.imageHash != nil {
            beginCropping(target)
            return
        }
        if clickCount == 2, let target, editor.document.layers[target]?.symbolInstance != nil {
            editor.select([target])
            editor.goToMaster()
            zoomToSelection()
            return
        }
        let extending = modifiers.contains(.shift)
        if let target {
            if extending {
                let selection = editor.selection
                editor.select(selection.contains(target) ? selection.filter { $0 != target } : selection + [target])
                return
            }
            let wasSelected = editor.selection.contains(target)
            if !wasSelected { editor.select([target]) }
            interaction = .pressing(start: world, startView: point, target: wasSelected ? target : nil)
        } else {
            let base = extending ? editor.selection : []
            if !extending { editor.select([]) }
            interaction = .marquee(start: world, current: world, base: base)
        }
    }

    private func updateMove(from start: CGPoint, box: CGRect, to world: CGPoint, modifiers: NSEvent.ModifierFlags) {
        var dx = (world.x - start.x).rounded()
        var dy = (world.y - start.y).rounded()
        if modifiers.contains(.shift) {
            if abs(dx) > abs(dy) { dy = 0 } else { dx = 0 }
        }
        guides = []
        if let snapper, !modifiers.contains(.control) {
            let (offset, snapGuides) = snapper.snap(moving: box.offsetBy(dx: dx, dy: dy))
            // A shift-constrained move only snaps along its own axis.
            let alongX = !modifiers.contains(.shift) || dy == 0
            let alongY = !modifiers.contains(.shift) || dy != 0
            if alongX { dx += offset.dx.rounded() }
            if alongY { dy += offset.dy.rounded() }
            guides = snapGuides
        }
        let selection = editor.selection
        let pageID = editor.pageID
        editor.updateLiveEdit { transaction in
            transaction.move(selection, by: CGVector(dx: dx, dy: dy))
            transaction.adoptIntoArtboards(selection, on: pageID)
        }
    }

    private func beginCreating(_ tool: Tool, at point: CGPoint) {
        prepareSnapping(for: [])
        var world = viewport.toCanvas(point).rounded
        if let snapper, !NSEvent.modifierFlags.contains(.control) { world = snapper.snap(point: world).point }
        let artboard = tool == .artboard ? nil : editor.document.artboard(at: world, on: editor.pageID)
        guard let layer = tool.makeLayer(from: world, to: world) else { return }
        let creation = Creation(tool: tool, layerID: layer.id, parent: artboard.map(LayerParent.layer) ?? .page(editor.pageID), start: world, startView: point)
        editor.beginLiveEdit()
        interaction = .creating(creation)
        updateCreation(creation, to: world, square: false, fromCenter: false)
    }

    private func updateCreation(_ creation: Creation, to world: CGPoint, square: Bool, fromCenter: Bool) {
        var end = world.rounded
        let start = creation.start
        if square {
            let dx = end.x - start.x
            let dy = end.y - start.y
            if creation.tool == .line {
                // Lines snap to multiples of 45°.
                if abs(dx) > 2 * abs(dy) { end.y = start.y } else if abs(dy) > 2 * abs(dx) { end.x = start.x } else {
                    let length = max(abs(dx), abs(dy))
                    end = CGPoint(x: start.x + length * (dx < 0 ? -1 : 1), y: start.y + length * (dy < 0 ? -1 : 1))
                }
            } else {
                let length = max(abs(dx), abs(dy))
                end = CGPoint(x: start.x + length * (dx < 0 ? -1 : 1), y: start.y + length * (dy < 0 ? -1 : 1))
            }
        }
        let origin = fromCenter ? CGPoint(x: 2 * start.x - end.x, y: 2 * start.y - end.y) : start

        let space: CGAffineTransform
        if case .layer(let parentID) = creation.parent {
            space = editor.document.contentsTransform(of: parentID).inverted()
        } else {
            space = .identity
        }
        guard var layer = creation.tool.makeLayer(from: origin.applying(space), to: end.applying(space)) else { return }
        layer.id = creation.layerID
        editor.updateLiveEdit(select: [creation.layerID]) { $0.insert(layer, into: creation.parent) }
    }

    /// Collects what the dragged layers can snap to: visible layers at the clickable level.
    private func prepareSnapping(for ids: [LayerID]) {
        let visible = viewport.toCanvas(bounds).insetBy(dx: -bounds.width / viewport.zoom, dy: -bounds.height / viewport.zoom)
        let targets = Snapper.targets(for: ids, on: editor.page, in: editor.document, area: visible)
        snapper = Snapper(targets: targets, threshold: 6 / viewport.zoom)
    }

    // MARK: Hit testing

    private func clickTarget(at point: CGPoint, deep: Bool) -> LayerID? {
        if let artboard = artboardTitle(at: point) { return artboard }
        let tester = HitTester(document: editor.document, tolerance: 4 / viewport.zoom)
        let path = tester.path(at: viewport.toCanvas(point), on: editor.page)
        return SelectionRules.clickTarget(path: path, in: editor.document, selection: editor.selection, deep: deep)
    }

    private func doubleClickTarget(at point: CGPoint) -> LayerID? {
        let tester = HitTester(document: editor.document, tolerance: 4 / viewport.zoom)
        let path = tester.path(at: viewport.toCanvas(point), on: editor.page)
        return SelectionRules.doubleClickTarget(path: path, in: editor.document, selection: editor.selection)
    }

    private func artboardTitle(at point: CGPoint) -> LayerID? {
        CanvasOverlay.artboardTitles(document: editor.document, page: editor.page, viewport: viewport)
            .last { $0.rect.contains(point) }?.id
    }

    private func handle(at point: CGPoint) -> SelectionHandle? {
        guard !editor.selection.isEmpty, let box = editor.document.worldBounds(of: editor.selection) else { return nil }
        return SelectionHandle.handle(at: point, box: viewport.toView(box))
    }

    // MARK: Pointer

    private func location(of event: NSEvent) -> CGPoint {
        convert(event.locationInWindow, from: nil)
    }

    private func trackPointer(_ point: CGPoint) {
        lastMouse = point
        state.cursor = bounds.contains(point) ? viewport.toCanvas(point) : nil
        updateCursor()
    }

    private func updateCursor() {
        let cursor: NSCursor
        if editor.tool == .pen || penSession != nil {
            cursor = .crosshair
        } else if isSpaceHeld || interaction.isPanning {
            cursor = interaction.isPanning ? .closedHand : .openHand
        } else if editor.tool != .select || interaction.isCreating {
            cursor = .crosshair
        } else if let crop = cropEdit, let cursor = cropCursor(crop) {
            return cursor.set()
        } else if case .resizing(let handle, _, _) = interaction {
            cursor = handle.cursor
        } else if let lastMouse, let handle = handle(at: lastMouse) {
            cursor = handle.cursor
        } else {
            cursor = .arrow
        }
        cursor.set()
    }

    override func cursorUpdate(with event: NSEvent) {
        updateCursor()
    }
}

/// What the mouse is doing on the canvas.
enum CanvasInteraction {
    case idle
    case panning(mouse: CGPoint, origin: CGPoint)
    /// The button is down on a layer but has not moved far enough to drag. `target` is set when
    /// the layer was already selected, so a click without a drag selects only it.
    case pressing(start: CGPoint, startView: CGPoint, target: LayerID?)
    /// `box` is the selection's page bounds when the drag started.
    case moving(start: CGPoint, box: CGRect)
    case resizing(handle: SelectionHandle, box: CGRect, start: CGPoint)
    case creating(Creation)
    case marquee(start: CGPoint, current: CGPoint, base: [LayerID])

    var isActive: Bool {
        if case .idle = self { return false }
        return true
    }

    var isPanning: Bool {
        if case .panning = self { return true }
        return false
    }

    var isCreating: Bool {
        if case .creating = self { return true }
        return false
    }

    var hidesHandles: Bool {
        switch self {
        case .moving, .creating: true
        default: false
        }
    }

    var marqueeRect: CGRect? {
        guard case .marquee(let start, let current, _) = self else { return nil }
        return CGRect(x: min(start.x, current.x), y: min(start.y, current.y), width: abs(current.x - start.x), height: abs(current.y - start.y))
    }
}

struct Creation {
    let tool: Tool
    let layerID: LayerID
    let parent: LayerParent
    /// Page coordinates, rounded to whole points.
    let start: CGPoint
    let startView: CGPoint
    var dragged = false
}

/// A transparent layer of the canvas that draws with a closure and lets the canvas handle events.
final class CanvasLayerView: NSView {
    private let drawing: (CGRect) -> Void
    private let drawsOpaque: Bool

    init(isOpaque: Bool, drawing: @escaping (CGRect) -> Void) {
        self.drawing = drawing
        self.drawsOpaque = isOpaque
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { drawsOpaque }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        drawing(dirtyRect)
    }
}

extension CGPoint {
    var rounded: CGPoint { CGPoint(x: x.rounded(), y: y.rounded()) }
}

extension NSColor {
    static let skicaCanvas = NSColor(name: "skicaCanvas") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 0.13, alpha: 1)
            : NSColor(white: 0.95, alpha: 1)
    }
}
