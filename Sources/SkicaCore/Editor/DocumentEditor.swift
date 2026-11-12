import Foundation
import Observation

/// The live state of one open document: the model, the current page, selection and tool.
/// Every edit goes through `perform` (or a live edit for drags), which records undo and tells
/// the canvas and panels exactly what changed.
@Observable
public final class DocumentEditor {
    public enum Change {
        case document(Patch)
        case selection
        case tool
        /// Another page is shown.
        case page
    }

    @ObservationIgnored public private(set) var document: Document
    /// Bumped on every document change so SwiftUI views that read the document refresh.
    public private(set) var revision = 0
    public private(set) var pageID: PageID
    public private(set) var selection: [LayerID] = []
    public var tool: Tool = .select {
        didSet { if tool != oldValue { notify(.tool) } }
    }

    @ObservationIgnored public weak var undoManager: UndoManager?
    @ObservationIgnored private var observers: [(Change) -> Void] = []
    @ObservationIgnored private var liveEdit: LiveEdit?
    @ObservationIgnored private var lastEntry: UndoEntry?

    public init(document: Document) {
        self.document = document
        self.pageID = document.pages[0].id
    }

    public var page: Page { document.page(pageID) ?? document.pages[0] }
    public var selectedLayers: [Layer] { selection.compactMap { document.layers[$0] } }
    public var isLiveEditing: Bool { liveEdit != nil }

    public func observe(_ handler: @escaping (Change) -> Void) {
        observers.append(handler)
    }

    /// Replaces the whole document, e.g. after "Revert to Saved".
    public func replaceDocument(_ document: Document) {
        self.document = document
        pageID = document.pages[0].id
        selection = []
        lastEntry = nil
        liveEdit = nil
        notify(.page)
        notify(.document(Patch(pages: PagesChange(before: [], after: document.pages))))
    }

    // MARK: Pages

    public func showPage(_ id: PageID) {
        guard id != pageID, document.page(id) != nil else { return }
        cancelLiveEdit()
        pageID = id
        selection = []
        notify(.page)
        notify(.selection)
    }

    /// Keeps the current page valid after pages were removed (or restored) by an edit or undo.
    private func ensureValidPage() -> Bool {
        guard document.page(pageID) == nil else { return false }
        pageID = document.pages[0].id
        return true
    }

    // MARK: Selection

    public func select(_ ids: [LayerID]) {
        let valid = sanitized(ids)
        guard valid != selection else { return }
        selection = valid
        notify(.selection)
    }

    private func sanitized(_ ids: [LayerID]) -> [LayerID] {
        var seen = Set<LayerID>()
        return ids.filter { id in
            document.layers[id] != nil && document.pageID(of: id) == pageID && seen.insert(id).inserted
        }
    }

    // MARK: Edits

    /// Applies an edit as one undo step named `actionName`. Edits with the same `coalescingKey`
    /// in quick succession (e.g. arrow-key nudges) merge into one step.
    @discardableResult
    public func perform(_ actionName: String, coalescingKey: String? = nil, select newSelection: [LayerID]? = nil, _ body: (inout Transaction) -> Void) -> Bool {
        var transaction = Transaction(document)
        body(&transaction)
        return commit(transaction, actionName: actionName, coalescingKey: coalescingKey, select: newSelection)
    }

    /// Like `perform`, for edits that decide the new selection themselves (paste, duplicate).
    @discardableResult
    public func performSelecting(_ actionName: String, _ body: (inout Transaction) -> [LayerID]) -> Bool {
        var transaction = Transaction(document)
        let newSelection = body(&transaction)
        return commit(transaction, actionName: actionName, coalescingKey: nil, select: newSelection)
    }

    private func commit(_ transaction: Transaction, actionName: String, coalescingKey: String?, select newSelection: [LayerID]?) -> Bool {
        var transaction = transaction
        transaction.finalize()
        let patch = transaction.patch
        guard !patch.isEmpty else {
            if let newSelection { select(newSelection) }
            return false
        }
        let before = selection
        document = transaction.document
        let pageChanged = ensureValidPage()
        selection = sanitized(newSelection ?? selection)
        record(patch, name: actionName, key: coalescingKey, selectionBefore: before)
        if pageChanged { notify(.page) }
        notifyDocumentChange(patch, selectionChanged: before != selection)
        return true
    }

    /// Starts an edit that follows the mouse: each update is computed from the state at the start,
    /// and the whole drag becomes one undo step when it ends.
    public func beginLiveEdit() {
        liveEdit = LiveEdit(start: document, selectionBefore: selection, patch: Patch())
    }

    public func updateLiveEdit(select newSelection: [LayerID]? = nil, _ body: (inout Transaction) -> Void) {
        guard var live = liveEdit else { return }
        var transaction = Transaction(live.start)
        body(&transaction)
        transaction.finalize()
        let patch = transaction.patch
        let delta = live.patch.inverse.then(patch)
        live.patch = patch
        liveEdit = live
        document = transaction.document
        let before = selection
        if let newSelection { selection = sanitized(newSelection) }
        if !delta.isEmpty {
            notifyDocumentChange(delta, selectionChanged: before != selection)
        } else if before != selection {
            notify(.selection)
        }
    }

    public func endLiveEdit(_ actionName: String) {
        guard let live = liveEdit else { return }
        liveEdit = nil
        guard !live.patch.isEmpty else { return }
        record(live.patch, name: actionName, key: nil, selectionBefore: live.selectionBefore)
    }

    public func cancelLiveEdit() {
        guard let live = liveEdit else { return }
        liveEdit = nil
        let revert = live.patch.inverse
        document = live.start
        selection = sanitized(live.selectionBefore)
        if !revert.isEmpty { notifyDocumentChange(revert, selectionChanged: true) }
    }

    /// Keeps the next edit from merging into the previous undo step (called after saving).
    public func breakCoalescing() {
        lastEntry = nil
    }

    // MARK: Undo

    private final class UndoEntry {
        var patch: Patch
        let name: String
        let key: String?
        var time: Date
        let selectionBefore: [LayerID]
        var selectionAfter: [LayerID]

        init(patch: Patch, name: String, key: String?, selectionBefore: [LayerID], selectionAfter: [LayerID]) {
            self.patch = patch
            self.name = name
            self.key = key
            self.time = Date()
            self.selectionBefore = selectionBefore
            self.selectionAfter = selectionAfter
        }
    }

    private struct LiveEdit {
        let start: Document
        let selectionBefore: [LayerID]
        var patch: Patch
    }

    private static let coalescingWindow: TimeInterval = 1.5

    private func record(_ patch: Patch, name: String, key: String?, selectionBefore: [LayerID]) {
        if let key, let last = lastEntry, last.key == key, Date().timeIntervalSince(last.time) < Self.coalescingWindow {
            last.patch = last.patch.then(patch)
            last.time = Date()
            last.selectionAfter = selection
            return
        }
        let entry = UndoEntry(patch: patch, name: name, key: key, selectionBefore: selectionBefore, selectionAfter: selection)
        lastEntry = entry
        // Without automatic grouping per event (e.g. in tests), each edit is its own group.
        let groupsItself = undoManager?.groupsByEvent == false
        if groupsItself { undoManager?.beginUndoGrouping() }
        registerUndo(of: entry)
        if groupsItself { undoManager?.endUndoGrouping() }
    }

    private func registerUndo(of entry: UndoEntry) {
        undoManager?.registerUndo(withTarget: self) { editor in editor.undo(entry) }
        undoManager?.setActionName(entry.name)
    }

    private func undo(_ entry: UndoEntry) {
        lastEntry = nil
        applyHistory(entry.patch.inverse, selection: entry.selectionBefore)
        undoManager?.registerUndo(withTarget: self) { editor in editor.redo(entry) }
        undoManager?.setActionName(entry.name)
    }

    private func redo(_ entry: UndoEntry) {
        lastEntry = nil
        applyHistory(entry.patch, selection: entry.selectionAfter)
        registerUndo(of: entry)
    }

    private func applyHistory(_ patch: Patch, selection newSelection: [LayerID]) {
        cancelLiveEdit()
        document.apply(patch)
        let previousPage = pageID
        if let restoredPage = newSelection.lazy.compactMap(document.pageID(of:)).first {
            pageID = restoredPage
        }
        _ = ensureValidPage()
        selection = sanitized(newSelection)
        if pageID != previousPage { notify(.page) }
        notifyDocumentChange(patch, selectionChanged: true)
    }

    // MARK: Notifications

    private func notifyDocumentChange(_ patch: Patch, selectionChanged: Bool) {
        revision += 1
        notify(.document(patch))
        if selectionChanged { notify(.selection) }
    }

    private func notify(_ change: Change) {
        for observer in observers { observer(change) }
    }
}
