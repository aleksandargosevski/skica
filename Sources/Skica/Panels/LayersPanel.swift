import AppKit
import SkicaCore
import SwiftUI

/// The layer list of the current page, topmost first. Selection follows the canvas both ways;
/// ↩ or a double-click renames, arrows move through the list. Dragging rows reorders layers
/// and moves them into or out of groups and artboards. The eye on a row shows or hides its layer;
/// the funnel in the header shows only the selection on the canvas.
final class LayersPanel: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSTextFieldDelegate {
    private let editor: DocumentEditor
    private let state: EditorState
    private let outline = LayerOutlineView()
    private var items: [LayerID: LayerItem] = [:]
    private var isSyncingSelection = false
    /// The layers being dragged in the list.
    private var draggedIDs: [LayerID] = []
    private static let rowType = NSPasteboard.PasteboardType("io.github.aleksandargosevski.skica.layer-row")

    /// Called by the funnel in the header.
    var onToggleIsolation: () -> Void = {}

    init(editor: DocumentEditor, state: EditorState) {
        self.editor = editor
        self.state = state
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    var outlineView: NSOutlineView { outline }

    override func loadView() {
        let column = NSTableColumn(identifier: .init("layer"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.rowHeight = 24
        outline.style = .sourceList
        outline.allowsMultipleSelection = true
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.doubleAction = #selector(renameClickedRow)
        outline.onRename = { [weak self] in self?.beginRenaming() }
        outline.registerForDraggedTypes([Self.rowType])
        outline.setDraggingSourceOperationMask(.move, forLocal: true)
        outline.draggingDestinationFeedbackStyle = .sourceList

        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false

        let pages = NSHostingView(rootView: PagesList(editor: editor))
        // Only the height follows the SwiftUI content; the width is the panel's.
        pages.sizingOptions = [.intrinsicContentSize]
        pages.setContentHuggingPriority(.defaultLow, for: .horizontal)
        pages.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let header = NSHostingView(rootView: LayersHeader(state: state) { [weak self] in self?.onToggleIsolation() })
        header.sizingOptions = [.intrinsicContentSize]
        header.setContentHuggingPriority(.defaultLow, for: .horizontal)
        header.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let container = NSView()
        for subview in [pages, header, scroll] as [NSView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            pages.topAnchor.constraint(equalTo: container.topAnchor),
            pages.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            pages.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            header.topAnchor.constraint(equalTo: pages.bottomAnchor),
            header.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        view = container

        editor.observe { [weak self] change in self?.editorChanged(change) }
        outline.reloadData()
    }

    /// Starts renaming the first selected layer in place.
    func beginRenaming() {
        guard let id = editor.selection.first, let item = items[id] else { return }
        let row = outline.row(forItem: item)
        guard row >= 0 else { return }
        outline.scrollRowToVisible(row)
        view.window?.makeFirstResponder(outline)
        outline.editColumn(0, row: row, with: nil, select: true)
    }

    /// Dims the rows hidden by "Show Only Selection", or brings them back.
    func isolationChanged() {
        guard outline.numberOfRows > 0 else { return }
        outline.reloadData(forRowIndexes: IndexSet(0..<outline.numberOfRows), columnIndexes: [0])
    }

    // MARK: Editor changes

    private func editorChanged(_ change: DocumentEditor.Change) {
        switch change {
        case .document(let patch):
            if patch.changesStructure {
                outline.reloadData()
                items = items.filter { editor.document.layers[$0.key] != nil }
            } else {
                for id in patch.layers.keys {
                    if let item = items[id] { outline.reloadItem(item) }
                }
            }
            syncSelectionFromEditor()
        case .selection:
            syncSelectionFromEditor()
        case .page:
            outline.reloadData()
            syncSelectionFromEditor()
        case .tool:
            break
        }
    }

    private func syncSelectionFromEditor() {
        isSyncingSelection = true
        defer { isSyncingSelection = false }
        for id in editor.selection {
            for ancestor in editor.document.ancestors(of: id) {
                outline.expandItem(item(for: ancestor))
            }
        }
        let rows = IndexSet(editor.selection.map { outline.row(forItem: item(for: $0)) }.filter { $0 >= 0 })
        if rows != outline.selectedRowIndexes {
            outline.selectRowIndexes(rows, byExtendingSelection: false)
        }
        if let first = rows.first { outline.scrollRowToVisible(first) }
    }

    private func item(for id: LayerID) -> LayerItem {
        if let item = items[id] { return item }
        let item = LayerItem(id: id)
        items[id] = item
        return item
    }

    // MARK: Data source

    private func children(of item: Any?) -> [LayerID] {
        guard let item = item as? LayerItem else { return editor.page.layers.reversed() }
        return editor.document.layers[item.id]?.children.reversed() ?? []
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        children(of: item).count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        self.item(for: children(of: item)[index])
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let item = item as? LayerItem, let layer = editor.document.layers[item.id] else { return false }
        return layer.isContainer && !layer.children.isEmpty
    }

    // MARK: Drag and drop

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard let item = item as? LayerItem else { return nil }
        let writer = NSPasteboardItem()
        writer.setString(item.id.rawValue, forType: Self.rowType)
        return writer
    }

    func outlineView(_ outlineView: NSOutlineView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint,
                     forItems draggedItems: [Any]) {
        draggedIDs = draggedItems.compactMap { ($0 as? LayerItem)?.id }
    }

    func outlineView(_ outlineView: NSOutlineView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint,
                     operation: NSDragOperation) {
        draggedIDs = []
    }

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?,
                     proposedChildIndex index: Int) -> NSDragOperation {
        guard !draggedIDs.isEmpty, let target = dropTarget(item: item, index: index) else { return [] }
        return editor.document.canMove(draggedIDs, into: target.parent) ? .move : []
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        guard !draggedIDs.isEmpty, let target = dropTarget(item: item, index: index) else { return false }
        editor.moveLayers(draggedIDs, into: target.parent, at: target.index)
        if case .layer(let parent) = target.parent { outline.expandItem(self.item(for: parent)) }
        return true
    }

    /// The parent and child index (from the bottom) for a drop on `item` at the list's `index`
    /// (rows run from the top, and -1 means onto the item itself, which puts layers on top of it).
    private func dropTarget(item: Any?, index: Int) -> (parent: LayerParent, index: Int)? {
        let parent: LayerParent
        if let item = item as? LayerItem { parent = .layer(item.id) } else { parent = .page(editor.pageID) }
        let count = editor.document.childIDs(of: parent).count
        return (parent, index == NSOutlineViewDropOnItemIndex ? count : count - index)
    }

    // MARK: Delegate

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let item = item as? LayerItem, let layer = editor.document.layers[item.id] else { return nil }
        let cell = outlineView.makeView(withIdentifier: LayerCell.identifier, owner: self) as? LayerCell ?? LayerCell()
        let isIsolatedAway = state.isolation?.hides(layer.id, in: editor.document) ?? false
        cell.configure(with: layer, isIsolatedAway: isIsolatedAway) { [weak self] in self?.editor.toggleHidden([layer.id]) }
        cell.textField?.delegate = self
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !isSyncingSelection else { return }
        let ids = outline.selectedRowIndexes.compactMap { (outline.item(atRow: $0) as? LayerItem)?.id }
        editor.select(ids)
    }

    @objc private func renameClickedRow() {
        guard outline.clickedRow >= 0 else { return }
        outline.editColumn(0, row: outline.clickedRow, with: nil, select: true)
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        let row = outline.row(for: field)
        guard row >= 0, let item = outline.item(atRow: row) as? LayerItem else { return }
        editor.rename(item.id, to: field.stringValue)
        if let layer = editor.document.layers[item.id] { field.stringValue = layer.name }
        view.window?.makeFirstResponder(outline)
    }
}

/// Outline items must be objects; one per layer ID, reused so expansion survives reloads.
final class LayerItem: NSObject {
    let id: LayerID
    init(id: LayerID) { self.id = id }
}

final class LayerOutlineView: NSOutlineView {
    var onRename: () -> Void = {}

    override func keyDown(with event: NSEvent) {
        if KeyCodes.named[event.keyCode] == "enter" {
            onRename()
        } else {
            super.keyDown(with: event)
        }
    }
}

private final class LayerCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("LayerCell")
    private let icon = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let badges = NSImageView()
    private let eye = NSButton()
    private var isLayerVisible = true
    private var toggleVisibility: () -> Void = {}
    private var isHovered = false {
        didSet { updateEye() }
    }

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        name.isEditable = true
        name.lineBreakMode = .byTruncatingTail
        name.font = .systemFont(ofSize: 12)
        name.cell?.sendsActionOnEndEditing = true
        icon.contentTintColor = .secondaryLabelColor
        badges.contentTintColor = .tertiaryLabelColor
        eye.isBordered = false
        eye.bezelStyle = .inline
        eye.imagePosition = .imageOnly
        eye.contentTintColor = .secondaryLabelColor
        eye.target = self
        eye.action = #selector(eyeClicked)
        imageView = icon
        textField = name
        for view in [icon, name, badges, eye] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            name.centerYAnchor.constraint(equalTo: centerYAnchor),
            badges.leadingAnchor.constraint(greaterThanOrEqualTo: name.trailingAnchor, constant: 4),
            badges.trailingAnchor.constraint(equalTo: eye.leadingAnchor, constant: -4),
            badges.centerYAnchor.constraint(equalTo: centerYAnchor),
            eye.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            eye.centerYAnchor.constraint(equalTo: centerYAnchor),
            eye.widthAnchor.constraint(equalToConstant: 18),
        ])
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// `isIsolatedAway`: hidden on the canvas by "Show Only Selection", so shown dimmed.
    func configure(with layer: Layer, isIsolatedAway: Bool, toggleVisibility: @escaping () -> Void) {
        icon.image = NSImage(systemSymbolName: layer.symbolName, accessibilityDescription: layer.typeTitle)
        name.stringValue = layer.name
        name.textColor = layer.isVisible && !isIsolatedAway ? nil : .tertiaryLabelColor
        let badge = layer.isLocked ? "lock.fill" : layer.isMask ? "theatermasks" : nil
        badges.image = badge.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
        isLayerVisible = layer.isVisible
        self.toggleVisibility = toggleVisibility
        updateEye()
    }

    /// The eye shows on hover; a hidden layer always shows it crossed out.
    private func updateEye() {
        eye.image = NSImage(systemSymbolName: isLayerVisible ? "eye" : "eye.slash", accessibilityDescription: isLayerVisible ? "Hide" : "Show")
        eye.toolTip = isLayerVisible ? "Hide" : "Show"
        eye.isHidden = isLayerVisible && !isHovered
    }

    @objc private func eyeClicked() {
        toggleVisibility()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        isHovered = false
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
    }
}

/// The "Layers" title with the funnel that shows only the selection on the canvas.
private struct LayersHeader: View {
    let state: EditorState
    let toggleIsolation: () -> Void

    var body: some View {
        let isIsolating = state.isolation != nil
        HStack {
            Text("Layers")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer()
            IconButton(symbol: isIsolating ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle",
                       help: isIsolating ? "Show all layers" : "Show only the selection", isOn: isIsolating, action: toggleIsolation)
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .frame(height: 28)
    }
}
