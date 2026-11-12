import AppKit
import SkicaCore
import SwiftUI

/// One document window: layers on the left, the canvas, the inspector on the right and the
/// status line at the bottom. Runs commands from the keyboard router, menus and palette.
final class DocumentWindowController: NSWindowController, NSWindowDelegate, NSSplitViewDelegate, NSMenuItemValidation {
    let editor: DocumentEditor
    let state = EditorState()
    let canvas: CanvasView
    let layersPanel: LayersPanel
    private lazy var inspector = NSHostingView(rootView: InspectorView(editor: editor, textActions: TextActions(
        applyStyle: { [weak self] name, change in self?.applyTextStyle(name, change) },
        updateContent: { [weak self] name, body in self?.updateTextContent(name, body) },
        chooseFont: { [weak self] in self?.showFontPalette() }
    ), exportSelection: { [weak self] in self?.exportSelection() }, editPoints: { [weak self] in self?.editPoints() },
       perform: { [weak self] command in self?.perform(command) }))
    private let splitView = NSSplitView()
    private var overlayHost: NSView?
    /// Widths of the side panels; dragging a divider changes them for every window from then on.
    private var panelWidths = PanelWidths.load()
    private var lastCommandLine: String?
    /// Panels hidden by "Canvas Only", restored by toggling it again.
    private var panelsBeforeZen: (layers: Bool, inspector: Bool)?

    init(editor: DocumentEditor) {
        self.editor = editor
        canvas = CanvasView(editor: editor, state: state)
        layersPanel = LayersPanel(editor: editor)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.minSize = NSSize(width: 720, height: 420)
        window.tabbingMode = .preferred
        super.init(window: window)

        window.delegate = self
        window.contentView = makeContentView()
        canvas.onDropImages = { [weak self] files, data, point in
            if !files.isEmpty {
                self?.insertImages(at: point, urls: files)
            } else if let svg = ImageImport.svgData(from: NSPasteboard(name: .drag)) {
                self?.insertSVG(svg, name: "SVG", at: point)
            } else if let data {
                self?.insertImages([(data, "Image")], at: point)
            }
        }
        window.initialFirstResponder = canvas
        window.center()
        window.setFrameAutosaveName("SkicaDocumentWindow")
        window.layoutIfNeeded()
        placeDividers()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    var hasOverlay: Bool { overlayHost != nil }

    private var keymap: Keymap {
        (NSApp.delegate as? AppDelegate)?.keymap ?? Keymap()
    }

    // MARK: Commands

    func perform(_ command: CommandID) {
        switch command {
        case .toolSelect: editor.tool = .select
        case .toolRectangle: editor.tool = .rectangle
        case .toolOval: editor.tool = .oval
        case .toolLine: editor.tool = .line
        case .toolPolygon: editor.tool = .polygon
        case .toolStar: editor.tool = .star
        case .toolPen: editor.tool = .pen
        case .toolText: editor.tool = .text
        case .insertImage: chooseImages()
        case .toolArtboard: editor.tool = .artboard
        case .editGeometry: openPrompt()
        case .delete: editor.deleteSelectionDetachingInstances()
        case .duplicate: editor.duplicateSelection()
        case .selectAll: editor.selectAll()
        case .rename: rename()
        case .toggleHidden: editor.toggleHidden()
        case .toggleLocked: editor.toggleLocked()
        case .bringForward: editor.reorder(.forward)
        case .sendBackward: editor.reorder(.backward)
        case .bringToFront: editor.reorder(.front)
        case .sendToBack: editor.reorder(.back)
        case .group: editor.groupSelection()
        case .ungroup: editor.ungroupSelection()
        case .alignLeft, .alignHorizontalCenter, .alignRight, .alignTop, .alignVerticalCenter, .alignBottom:
            if let edge = command.alignEdge { editor.align(edge) }
        case .distributeHorizontally, .distributeVertically:
            guard editor.selection.count >= 3 else {
                showMessage("Distribute needs three or more layers. For a fixed gap, use the spacing fields or :distribute h 16.")
                return NSSound.beep()
            }
            editor.distribute(horizontally: command == .distributeHorizontally)
        case .addStack: editor.addStack()
        case .removeStack: editor.removeStack()
        case .selectNext: selectSibling(forward: true)
        case .selectPrevious: selectSibling(forward: false)
        case .enterSelection: enterSelection()
        case .escape: escape()
        case .zoomIn: canvas.zoomStep(up: true)
        case .zoomOut: canvas.zoomStep(up: false)
        case .zoomActualSize: canvas.zoomToActualSize()
        case .zoomToFit: canvas.zoomToFit()
        case .zoomToSelection: canvas.zoomToSelection()
        case .toggleLayers: setPanel(layersPanel.view, visible: layersPanel.view.isHidden)
        case .toggleInspector: setPanel(inspector, visible: inspector.isHidden)
        case .toggleZen: toggleZen()
        case .focusLayers: focusLayers()
        case .focusInspector: focusInspector()
        case .toggleBold: toggleFontTrait(.boldFontMask, name: "Bold")
        case .toggleItalic: toggleFontTrait(.italicFontMask, name: "Italic")
        case .toggleUnderline: toggleUnderline()
        case .chooseFont: showFontPalette()
        case .commandLine: openCommandLine()
        case .repeatCommand: repeatLastCommand()
        case .hintSelect: canvas.beginHints(adding: false)
        case .hintAdd: canvas.beginHints(adding: true)
        case .commandPalette: showPalette(.everything)
        case .selectionActions: showPalette(.selection)
        case .editPoints: editPoints()
        case .convertToPaths: editor.convertSelectionToPaths()
        case .outlineStroke: editor.outlineSelectionBorders()
        case .booleanUnion: editor.combineSelection(.union)
        case .booleanSubtract: editor.combineSelection(.subtract)
        case .booleanIntersect: editor.combineSelection(.intersect)
        case .booleanDifference: editor.combineSelection(.difference)
        case .toggleMask: editor.maskSelection()
        case .createSymbol, .insertSymbol, .swapSymbol, .goToMaster, .detachSymbol, .resetOverrides,
             .createSharedStyle, .applySharedStyle, .updateSharedStyle, .resetToSharedStyle, .detachSharedStyle,
             .applyColor, .addColorToPalette:
            performAssetCommand(command)
        case .exportSelection: exportSelection()
        case .exportMarked: exportMarked()
        case .exportPagePDF: exportPagePDF()
        case .copyAsPNG: copyAsPNG()
        case .copyAsSVG: copyAsSVG()
        case .newPage: editor.addPage()
        case .deletePage: confirmDeletePage()
        case .renamePage: openRenamePagePrompt()
        case .nextPage: editor.showAdjacentPage(forward: true)
        case .previousPage: editor.showAdjacentPage(forward: false)
        case .goToPage: showPalette(.pages(movingSelection: false))
        case .moveToPage: showPalette(.pages(movingSelection: true))
        case .showShortcuts: toggleShortcuts()
        }
    }

    @objc func performCommand(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let command = CommandID(rawValue: raw) else { return }
        perform(command)
    }

    /// Arrow keys on the canvas: move the selection, resize it with ⌘ (⌘⌥ from the other side),
    /// or pan when nothing is selected.
    func handleArrow(dx: Int, dy: Int, modifiers: NSEvent.ModifierFlags) {
        let step = modifiers.contains(.shift) ? 10.0 : 1.0
        if editor.selection.isEmpty {
            canvas.panByKeyboard(dx: CGFloat(-dx) * step * 40, dy: CGFloat(-dy) * step * 40)
        } else if modifiers.contains(.command) {
            let fromOpposite = modifiers.contains(.option)
            let sign = fromOpposite ? -1.0 : 1.0
            editor.resizeEdges(dx: Double(dx) * step * sign, dy: Double(dy) * step * sign, fromOpposite: fromOpposite)
        } else {
            editor.nudge(dx: Double(dx) * step, dy: Double(dy) * step)
        }
    }

    private func selectSibling(forward: Bool) {
        if let current = editor.selection.last {
            if let next = SelectionRules.sibling(of: current, in: editor.document, forward: forward) { editor.select([next]) }
        } else if let topmost = editor.page.layers.last {
            editor.select([topmost])
        }
        canvas.revealSelection()
    }

    /// ↩ adds the active tool's shape, enters a container, or edits size and position.
    private func enterSelection() {
        if editor.tool != .select {
            let tool = editor.tool
            var center = canvas.visibleCenter
            if editor.selection.count == 1, let selected = editor.selection.first,
               editor.document.layers[selected]?.isArtboard == true, tool != .artboard,
               let bounds = editor.document.worldBounds(of: selected) {
                center = CGPoint(x: bounds.midX, y: bounds.midY)
            }
            let inserted = editor.insertShape(tool, centeredAt: center)
            editor.tool = .select
            if tool == .text, let inserted {
                canvas.beginTextEditing(inserted)
            } else {
                openPrompt()
            }
        } else if editor.selection.count == 1, let selected = editor.selection.first,
                  editor.document.layers[selected]?.textContent != nil {
            canvas.beginTextEditing(selected)
        } else if editor.selection.count == 1, let selected = editor.selection.first,
                  editor.document.layers[selected]?.vectorPath != nil {
            canvas.beginPathEditing(selected)
        } else if editor.selection.count == 1, let selected = editor.selection.first,
                  let child = SelectionRules.firstChild(of: selected, in: editor.document) {
            editor.select([child])
            canvas.revealSelection()
        } else if !editor.selection.isEmpty {
            openPrompt()
        } else {
            NSSound.beep()
        }
    }

    /// Closes whatever is on top: an overlay, the prompt, a drag, a focused field, the tool,
    /// then climbs the selection to the parent and finally deselects.
    private func escape() {
        if overlayHost != nil { return closeOverlay() }
        if state.prompt != nil { return closePrompt() }
        if canvas.textSession != nil { return canvas.endTextEditing() }
        if canvas.penSession != nil { return canvas.finishPen(closed: false) }
        if canvas.pathEdit != nil { return canvas.endPathEditing() }
        if canvas.cancelInteraction() { return }
        if let responder = window?.firstResponder, responder !== canvas {
            window?.makeFirstResponder(canvas)
            return
        }
        if editor.tool != .select {
            editor.tool = .select
        } else if editor.selection.count == 1, let parent = editor.document.layers[editor.selection[0]]?.parent {
            editor.select([parent])
        } else {
            editor.select([])
        }
    }

    private func confirmDeletePage() {
        guard editor.document.pages.count > 1, let window else { return NSSound.beep() }
        let alert = NSAlert()
        alert.messageText = "Delete “\(editor.page.name)”?"
        alert.informativeText = "Everything on the page is deleted too. You can undo this."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertFirstButtonReturn { self?.editor.removeCurrentPage() }
        }
    }

    private func rename() {
        guard !editor.selection.isEmpty else { return NSSound.beep() }
        setPanel(layersPanel.view, visible: true)
        layersPanel.beginRenaming()
    }

    // MARK: Vectors

    /// Edits the points of the selected path (shapes become paths first).
    /// `e`: edit the points of a shape, or crop an image.
    private func editPoints() {
        guard editor.selection.count == 1, let id = editor.selection.first else { return NSSound.beep() }
        if editor.document.layers[id]?.imageHash != nil { return canvas.beginCropping(id) }
        canvas.beginPathEditing(id)
    }

    // MARK: Images

    private func chooseImages() {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.message = "Choose images to add"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let self else { return }
            self.insertImages(at: self.canvas.visibleCenter, urls: panel.urls)
        }
    }

    /// Bitmaps become image layers; SVG files become editable layers.
    func insertImages(at center: CGPoint, urls: [URL]) {
        var images: [(Data, String)] = []
        for url in urls {
            do {
                let data = try Data(contentsOf: url)
                let name = url.deletingPathExtension().lastPathComponent
                if ImageImport.isSVG(url) {
                    insertSVG(data, name: name, at: center, baseURL: url.deletingLastPathComponent())
                } else {
                    images.append((data, name))
                }
            } catch {
                presentError(error)
            }
        }
        if !images.isEmpty { insertImages(images, at: center) }
    }

    func insertSVG(_ data: Data, name: String, at center: CGPoint, baseURL: URL? = nil) {
        do {
            let clipboard = try SVGImporter.clipboard(from: data, name: name, baseURL: baseURL)
            editor.insertImported(clipboard, centeredAt: center, actionName: "Import SVG")
        } catch {
            presentError(error)
        }
    }

    /// Adds images (several are offset so they do not stack exactly) and selects them.
    func insertImages(_ images: [(data: Data, name: String)], at center: CGPoint) {
        var added: [LayerID] = []
        for (offset, image) in images.enumerated() {
            let point = CGPoint(x: center.x + CGFloat(offset * 20), y: center.y + CGFloat(offset * 20))
            if let id = editor.insertImage(image.data, named: image.name, centeredAt: point) {
                added.append(id)
            } else {
                NSSound.beep()
            }
        }
        if !added.isEmpty { editor.select(added) }
    }

    // MARK: Text

    /// Restyles text: the selected characters while typing, otherwise all text of the selected
    /// text layers.
    func applyTextStyle(_ actionName: String, _ change: @escaping (TextStyle) -> TextStyle) {
        if let session = canvas.textSession, let content = editor.document.layers[session.layerID]?.textContent {
            session.applyStyle(change, alignment: content.alignment)
            if session.selectedRange != nil { return }
        }
        editor.updateSelection(actionName) { layer in
            guard var content = layer.textContent else { return }
            content.updateStyles { $0 = change($0) }
            layer.kind = .text(content)
        }
    }

    func updateTextContent(_ actionName: String, _ body: @escaping (inout TextContent) -> Void) {
        editor.updateSelection(actionName) { layer in
            guard var content = layer.textContent else { return }
            body(&content)
            layer.kind = .text(content)
        }
    }

    /// Bold, italic: on for all when any selected text lacks it, otherwise off.
    private func toggleFontTrait(_ trait: NSFontTraitMask, name: String) {
        let styles = editor.selectedLayers.compactMap(\.textContent).flatMap { $0.runs.map(\.style) }
        guard !styles.isEmpty else { return NSSound.beep() }
        let turnOn = styles.contains { !$0.has(trait) }
        applyTextStyle(name) { $0.converting(trait, on: turnOn) }
    }

    private func toggleUnderline() {
        let styles = editor.selectedLayers.compactMap(\.textContent).flatMap { $0.runs.map(\.style) }
        guard !styles.isEmpty else { return NSSound.beep() }
        let turnOn = styles.contains { !$0.underline }
        applyTextStyle("Underline") { style in
            var style = style
            style.underline = turnOn
            return style
        }
    }

    /// Lists every installed font family; the chosen one keeps the closest weight.
    func showFontPalette() {
        guard editor.selectedLayers.contains(where: { $0.textContent != nil }) else { return NSSound.beep() }
        let items = NSFontManager.shared.availableFontFamilies.map { family in
            PaletteItem(id: "font-\(family)", title: family, symbol: "textformat", run: { [weak self] in
                self?.applyTextStyle("Change Font") { style in
                    var style = style
                    if let face = style.closestFace(in: family) { style.fontName = face }
                    return style
                }
            })
        }
        let palette = PaletteView(placeholder: "Font family…", items: items, search: { _ in [] }) { [weak self] in self?.closeOverlay() }
        showOverlay(AnyView(palette), alignment: .top)
    }

    // MARK: Prompt

    /// Size and position of the selection: `200x120 @ 40,80`.
    private func openPrompt() {
        let layers = editor.selectedLayers
        guard let first = layers.first else { return NSSound.beep() }
        let frame = first.frame
        let format = NumberField.display
        var placeholder = "\(format(frame.width))x\(format(frame.height)) @ \(format(frame.x)),\(format(frame.y))"
        if first.isArtboard { placeholder += "   or a preset: iphone, ipad, desktop, a4…" }
        state.prompt = PromptState(
            kind: .geometry,
            title: layers.count == 1 ? first.kind.title : "\(layers.count) Layers",
            placeholder: placeholder
        )
    }

    private func openRenamePagePrompt() {
        let page = editor.page
        state.prompt = PromptState(kind: .renamePage(page.id), title: "Rename Page", text: page.name, placeholder: page.name)
    }

    private func submitPrompt(_ text: String) {
        guard let prompt = state.prompt else { return }
        do {
            switch prompt.kind {
            case .geometry:
                let inputs = try editor.selectedLayers.map { ($0.id, try GeometryPrompt.parse(text, current: $0.frame)) }
                editor.perform("Change Size and Position") { transaction in
                    for (id, input) in inputs {
                        transaction.update(id) { $0.frame = input.applied(to: $0.frame) }
                    }
                }
            case .renamePage(let id):
                editor.renamePage(id, to: text)
            case .commandLine:
                let actions = try editor.run(commandLine: text)
                lastCommandLine = text
                actions.forEach(perform)
            case .createSymbol, .createSharedStyle:
                _ = submitAssetPrompt(prompt.kind, text: text)
            }
            closePrompt()
        } catch {
            state.prompt?.error = error.localizedDescription
        }
    }

    /// `:` opens a command line for the selection: `w 200`, `fill #f60`, `font Inter 16 600`…
    private func openCommandLine() {
        guard !editor.selection.isEmpty else { return NSSound.beep() }
        state.prompt = PromptState(kind: .commandLine, title: ":", placeholder: "w 200; fill #ff6600; font Inter 16 600")
    }

    /// `.` runs the last command line again, on the current selection.
    private func repeatLastCommand() {
        guard let lastCommandLine, !editor.selection.isEmpty else { return NSSound.beep() }
        do {
            try editor.run(commandLine: lastCommandLine).forEach(perform)
        } catch {
            NSSound.beep()
        }
    }

    func closePrompt() {
        state.prompt = nil
        window?.makeFirstResponder(canvas)
    }

    // MARK: Panels

    private func setPanel(_ panel: NSView, visible: Bool) {
        guard panel.isHidden == visible else { return }
        if !visible { rememberPanelWidths() }
        panel.isHidden = !visible
        splitView.adjustSubviews()
        placeDividers()
        if !visible, let window, panel.contains(window.firstResponder as? NSView) {
            window.makeFirstResponder(canvas)
        }
    }

    private func toggleZen() {
        if let before = panelsBeforeZen {
            panelsBeforeZen = nil
            setPanel(layersPanel.view, visible: before.layers)
            setPanel(inspector, visible: before.inspector)
        } else {
            panelsBeforeZen = (!layersPanel.view.isHidden, !inspector.isHidden)
            setPanel(layersPanel.view, visible: false)
            setPanel(inspector, visible: false)
        }
    }

    private func focusLayers() {
        setPanel(layersPanel.view, visible: true)
        if editor.selection.isEmpty, let topmost = editor.page.layers.last { editor.select([topmost]) }
        window?.makeFirstResponder(layersPanel.outlineView)
    }

    private func focusInspector() {
        setPanel(inspector, visible: true)
        if let field = inspector.firstEditableTextField {
            window?.makeFirstResponder(field)
        } else {
            NSSound.beep()
        }
    }

    /// Moves both dividers as dragging them would (for debug snapshots) and reports the widths.
    func debugResizePanels(layers: CGFloat, inspector inspectorWidth: CGFloat) -> String {
        splitView.setPosition(layers, ofDividerAt: 0)
        splitView.setPosition(splitView.bounds.width - inspectorWidth, ofDividerAt: 1)
        window?.layoutIfNeeded()
        return "layers \(layersPanel.view.frame.width), inspector \(inspector.frame.width)"
    }

    private func rememberPanelWidths() {
        if !layersPanel.view.isHidden, layersPanel.view.frame.width >= PanelWidths.minimumLayers { panelWidths.layers = layersPanel.view.frame.width }
        if !inspector.isHidden, inspector.frame.width >= PanelWidths.minimumInspector { panelWidths.inspector = inspector.frame.width }
    }

    private func placeDividers() {
        let total = splitView.bounds.width
        guard total > 0 else { return }
        if !layersPanel.view.isHidden { splitView.setPosition(panelWidths.layers, ofDividerAt: 0) }
        if !inspector.isHidden { splitView.setPosition(total - panelWidths.inspector, ofDividerAt: 1) }
    }

    // MARK: Overlays

    private enum PaletteMode {
        /// Commands, plus layers and pages matching the query.
        case everything
        /// Commands that act on the selection.
        case selection
        /// Pages, to show one or to move the selection there.
        case pages(movingSelection: Bool)
    }

    private func showPalette(_ mode: PaletteMode) {
        let items: [PaletteItem]
        var search: (String) -> [PaletteItem] = { _ in [] }
        let placeholder: String
        switch mode {
        case .everything:
            items = commandItems { $0 != .escape && $0 != .commandPalette && $0 != .selectionActions }
            search = { [weak self] query in (self?.pageItems(movingSelection: false) ?? []) + (self?.layerItems(matching: query) ?? []) }
            placeholder = "Search commands, layers and pages…"
        case .selection:
            if editor.selection.isEmpty { return NSSound.beep() }
            items = commandItems(\.needsSelection)
            placeholder = "Actions for the selection…"
        case .pages(let movingSelection):
            if movingSelection, editor.selection.isEmpty { return NSSound.beep() }
            items = pageItems(movingSelection: movingSelection)
            placeholder = movingSelection ? "Move the selection to page…" : "Go to page…"
        }
        let palette = PaletteView(placeholder: placeholder, items: items, search: search) { [weak self] in self?.closeOverlay() }
        showOverlay(AnyView(palette), alignment: .top)
    }


    private func commandItems(_ include: (CommandID) -> Bool) -> [PaletteItem] {
        let keymap = keymap
        return CommandID.allCases.filter(include).map { command in
            PaletteItem(
                id: command.rawValue,
                title: command.title,
                subtitle: command.category.rawValue,
                symbol: command.symbolName,
                shortcut: keymap.primary(for: command)?.displayText,
                run: { [weak self] in self?.perform(command) }
            )
        }
    }

    private func pageItems(movingSelection: Bool) -> [PaletteItem] {
        editor.document.pages.compactMap { page in
            if movingSelection, page.id == editor.pageID { return nil }
            return PaletteItem(
                id: "page-\(page.id)",
                title: page.name,
                subtitle: page.id == editor.pageID ? "Current page" : "Page",
                symbol: "doc",
                run: { [weak self] in
                    if movingSelection { self?.editor.moveSelection(toPage: page.id) } else { self?.editor.showPage(page.id) }
                }
            )
        }
    }

    private func layerItems(matching query: String) -> [PaletteItem] {
        let document = editor.document
        return document.listOrder(of: editor.page).compactMap { id in
            guard let layer = document.layers[id], FuzzyMatch.score(query, in: layer.name) != nil else { return nil }
            let parentName = layer.parent.flatMap { document.layers[$0]?.name }
            return PaletteItem(
                id: id.rawValue,
                title: layer.name,
                subtitle: parentName.map { "in \($0)" } ?? "Layer",
                symbol: layer.kind.symbolName,
                run: { [weak self] in
                    self?.editor.select([id])
                    self?.canvas.revealSelection()
                }
            )
        }
    }

    private func toggleShortcuts() {
        if overlayHost != nil { return closeOverlay() }
        showOverlay(AnyView(ShortcutsView(keymap: keymap)), alignment: .center)
    }

    func showOverlay(_ content: AnyView, alignment: Alignment) {
        closeOverlay()
        guard let contentView = window?.contentView else { return }
        let root = ZStack(alignment: alignment) {
            SwiftUI.Color.black.opacity(0.001)
                .onTapGesture { [weak self] in self?.closeOverlay() }
            content.padding(.top, alignment == .top ? 80 : 0)
        }
        let host = NSHostingView(rootView: root)
        host.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(host)
        NSLayoutConstraint.activate([
            host.topAnchor.constraint(equalTo: contentView.topAnchor),
            host.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            host.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
        ])
        overlayHost = host
        if alignment != .top { window?.makeFirstResponder(host) }
    }

    func closeOverlay() {
        guard let host = overlayHost else { return }
        overlayHost = nil
        host.removeFromSuperview()
        window?.makeFirstResponder(canvas)
    }

    // MARK: Responder chain (Edit menu)

    @objc func copy(_ sender: Any?) {
        do {
            try editor.copySelection()
        } catch {
            presentError(error)
        }
    }

    @objc func cut(_ sender: Any?) {
        do {
            try editor.copySelection()
            editor.deleteSelectionDetachingInstances()
        } catch {
            presentError(error)
        }
    }

    @objc func paste(_ sender: Any?) {
        do {
            if editor.canPaste {
                try editor.paste()
            } else if let svg = ImageImport.svgData(from: .general) {
                insertSVG(svg, name: "SVG", at: canvas.visibleCenter)
            } else if let image = ImageImport.imageData(from: .general) {
                insertImages([(image, "Image")], at: canvas.visibleCenter)
            }
        } catch {
            presentError(error)
        }
    }

    @objc override func selectAll(_ sender: Any?) {
        editor.selectAll()
    }

    @objc func delete(_ sender: Any?) {
        editor.deleteSelectionDetachingInstances()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(copy(_:)), #selector(cut(_:)), #selector(delete(_:)):
            return !editor.selection.isEmpty
        case #selector(paste(_:)):
            return editor.canPaste || ImageImport.hasImage(on: .general)
        case #selector(performCommand(_:)):
            guard let raw = menuItem.representedObject as? String, let command = CommandID(rawValue: raw) else { return false }
            if command == .toggleLayers { menuItem.title = layersPanel.view.isHidden ? "Show Layers" : "Hide Layers" }
            if command == .toggleInspector { menuItem.title = inspector.isHidden ? "Show Inspector" : "Hide Inspector" }
            if menuItem.representedObject as? String == editor.tool.commandID?.rawValue { menuItem.state = .on } else if command.category == .tools { menuItem.state = .off }
            if command == .deletePage { return editor.document.pages.count > 1 }
            return !command.needsSelection || !editor.selection.isEmpty
        default:
            return true
        }
    }

    // MARK: Window

    func windowDidResignKey(_ notification: Notification) {
        canvas.isSpaceHeld = false
        state.pendingKeys = []
    }

    // MARK: Split view

    /// Panels keep their width between a minimum and half of the window; the canvas keeps 300 points.
    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        dividerIndex == 0 ? PanelWidths.minimumLayers : max(proposedMinimumPosition, layersPanel.view.frame.maxX + 300)
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        let width = splitView.bounds.width
        let inspectorWidth = inspector.isHidden ? 0 : inspector.frame.width
        return dividerIndex == 0 ? min(width / 2, width - inspectorWidth - 300) : width - PanelWidths.minimumInspector
    }

    /// Resizing the window resizes the canvas only.
    func splitView(_ splitView: NSSplitView, shouldAdjustSizeOfSubview view: NSView) -> Bool {
        view === canvas
    }

    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool {
        false
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        // Only a divider drag (a mouse event) is the user's choice of width; window resizes are not.
        guard NSApp.currentEvent?.type == .leftMouseDragged else { return }
        rememberPanelWidths()
        panelWidths.save()
    }

    private func makeContentView() -> NSView {
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.autosaveName = nil
        splitView.delegate = self
        // Plain subviews, not arranged ones: the split view sets their frames and the delegate
        // limits the dividers. (With Auto Layout, SwiftUI's size constraints fight the dividers.)
        for view in [layersPanel.view, canvas, inspector] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = true
            splitView.addSubview(view)
        }
        inspector.sizingOptions = []

        let statusBar = NSHostingView(rootView: StatusBar(state: state, editor: editor) { [weak self] text in
            self?.submitPrompt(text)
        })
        let container = NSView()
        for view in [splitView, statusBar] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
        }
        NSLayoutConstraint.activate([
            splitView.topAnchor.constraint(equalTo: container.topAnchor),
            splitView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            splitView.bottomAnchor.constraint(equalTo: statusBar.topAnchor),
            statusBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            statusBar.heightAnchor.constraint(equalToConstant: 24),
        ])
        return container
    }
}

private extension NSView {
    func contains(_ view: NSView?) -> Bool {
        guard let view else { return false }
        return view === self || view.isDescendant(of: self)
    }

    /// The first editable text field, top to bottom, for focusing a panel from the keyboard.
    var firstEditableTextField: NSTextField? {
        var fields: [NSTextField] = []
        func collect(_ view: NSView) {
            if let field = view as? NSTextField, field.isEditable, !field.isHidden { fields.append(field) }
            view.subviews.forEach(collect)
        }
        collect(self)
        return fields.min { lhs, rhs in
            let left = lhs.convert(lhs.bounds.origin, to: nil)
            let right = rhs.convert(rhs.bounds.origin, to: nil)
            return left.y != right.y ? left.y > right.y : left.x < right.x
        }
    }
}

extension Tool {
    var commandID: CommandID? {
        switch self {
        case .select: .toolSelect
        case .rectangle: .toolRectangle
        case .oval: .toolOval
        case .line: .toolLine
        case .polygon: .toolPolygon
        case .star: .toolStar
        case .pen: .toolPen
        case .text: .toolText
        case .artboard: .toolArtboard
        }
    }
}

extension CommandID {
    var symbolName: String {
        switch self {
        case .toolSelect: "cursorarrow"
        case .toolRectangle: "rectangle"
        case .toolOval: "circle"
        case .toolLine: "line.diagonal"
        case .toolPolygon: "pentagon"
        case .toolStar: "star"
        case .toolPen: "pencil.tip"
        case .toolText: "textformat"
        case .insertImage: "photo"
        case .toolArtboard: "rectangle.dashed"
        case .delete: "trash"
        case .duplicate: "plus.square.on.square"
        case .rename: "pencil"
        case .toggleHidden: "eye.slash"
        case .toggleLocked: "lock"
        case .alignLeft: "align.horizontal.left"
        case .alignHorizontalCenter: "align.horizontal.center"
        case .alignRight: "align.horizontal.right"
        case .alignTop: "align.vertical.top"
        case .alignVerticalCenter: "align.vertical.center"
        case .alignBottom: "align.vertical.bottom"
        case .distributeHorizontally: "distribute.horizontal"
        case .distributeVertically: "distribute.vertical"
        case .addStack, .removeStack: "square.split.1x2"
        case .group: "folder.badge.plus"
        case .ungroup: "folder.badge.minus"
        case .bringForward, .bringToFront: "square.3.layers.3d.top.filled"
        case .sendBackward, .sendToBack: "square.3.layers.3d.bottom.filled"
        case .zoomIn, .zoomToSelection: "plus.magnifyingglass"
        case .zoomOut: "minus.magnifyingglass"
        case .zoomActualSize, .zoomToFit: "arrow.up.left.and.arrow.down.right"
        case .toggleLayers: "sidebar.left"
        case .toggleInspector: "sidebar.right"
        case .showShortcuts: "keyboard"
        case .commandLine: "terminal"
        case .repeatCommand: "repeat"
        case .hintSelect, .hintAdd: "character.cursor.ibeam"
        case .toggleBold: "bold"
        case .toggleItalic: "italic"
        case .toggleUnderline: "underline"
        case .chooseFont: "textformat"
        case .editPoints: "point.topleft.down.to.point.bottomright.curvepath"
        case .convertToPaths, .outlineStroke: "skew"
        case .booleanUnion: "square.on.square"
        case .booleanSubtract: "square.on.square.dashed"
        case .booleanIntersect: "square.on.square.intersection.dashed"
        case .booleanDifference: "square.split.diagonal"
        case .toggleMask: "theatermasks"
        case .createSymbol, .insertSymbol, .swapSymbol, .goToMaster: "diamond"
        case .detachSymbol: "diamond.bottomhalf.filled"
        case .resetOverrides: "arrow.uturn.backward"
        case .createSharedStyle, .applySharedStyle, .updateSharedStyle, .resetToSharedStyle, .detachSharedStyle: "paintpalette"
        case .applyColor, .addColorToPalette: "circle.fill"
        case .exportSelection, .exportMarked: "square.and.arrow.up"
        case .exportPagePDF: "doc.richtext"
        case .copyAsPNG, .copyAsSVG: "doc.on.clipboard"
        case .newPage: "doc.badge.plus"
        case .deletePage: "trash"
        case .renamePage: "pencil"
        case .nextPage, .previousPage, .goToPage: "doc"
        case .moveToPage: "arrow.right.doc.on.clipboard"
        default: "command"
        }
    }
}

/// The side panels' widths, kept in the user defaults.
private struct PanelWidths {
    static let minimumLayers: CGFloat = 160
    static let minimumInspector: CGFloat = 240
    private static let key = "SkicaPanelWidths"

    var layers: CGFloat
    var inspector: CGFloat

    static func load() -> PanelWidths {
        let saved = UserDefaults.standard.dictionary(forKey: key) as? [String: Double]
        return PanelWidths(layers: max(saved?["layers"] ?? 240, minimumLayers), inspector: max(saved?["inspector"] ?? 290, minimumInspector))
    }

    func save() {
        UserDefaults.standard.set(["layers": Double(layers), "inspector": Double(inspector)], forKey: Self.key)
    }
}
