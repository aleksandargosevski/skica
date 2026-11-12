import Foundation

/// Collects changes to a copy of a document and reports them as a `Patch`.
/// All edits go through transactions, which keeps undo, redraw and layout in sync.
public struct Transaction {
    public let original: Document
    public private(set) var document: Document
    /// Layers changed, added or removed so far.
    public private(set) var touched: Set<LayerID> = []

    public init(_ document: Document) {
        original = document
        self.document = document
    }

    public var patch: Patch {
        var changes: [LayerID: LayerChange] = [:]
        for id in touched {
            let before = original.layers[id]
            let after = document.layers[id]
            if before != after { changes[id] = LayerChange(before: before, after: after) }
        }
        let pages = original.pages == document.pages ? nil : PagesChange(before: original.pages, after: document.pages)
        let assets = original.assets == document.assets ? nil : AssetsChange(before: original.assets, after: document.assets)
        return Patch(layers: changes, pages: pages, assets: assets)
    }

    public subscript(id: LayerID) -> Layer? {
        document.layers[id]
    }

    public mutating func update(_ id: LayerID, _ body: (inout Layer) -> Void) {
        guard var layer = document.layers[id] else { return }
        body(&layer)
        layer.id = id
        document.layers[id] = layer
        touched.insert(id)
    }

    public mutating func updatePage(_ id: PageID, _ body: (inout Page) -> Void) {
        guard let index = document.pages.firstIndex(where: { $0.id == id }) else { return }
        body(&document.pages[index])
        document.pages[index].id = id
    }

    /// Changes shared styles or swatches; the patch records them for undo.
    public mutating func updateAssets(_ body: (inout DocumentAssets) -> Void) {
        body(&document.assets)
    }

    mutating func storeImage(_ data: Data, hash: String) {
        document.images[hash] = data
    }

    /// Replaces the page list (adding, removing or reordering pages); the patch records it whole.
    mutating func replacePages(_ pages: [Page]) {
        document.pages = pages
    }

    /// Adds a new layer (without children) to `parent`; `index` counts from the bottom, nil puts it on top.
    public mutating func insert(_ layer: Layer, into parent: LayerParent, at index: Int? = nil) {
        var layer = layer
        layer.children = []
        layer.parent = nil
        document.layers[layer.id] = layer
        touched.insert(layer.id)
        attach(layer.id, to: parent, at: index)
    }

    /// Removes a layer and everything inside it.
    public mutating func remove(_ id: LayerID) {
        guard document.layers[id] != nil else { return }
        detach(id)
        for descendant in document.subtree(of: id) {
            document.layers[descendant] = nil
            touched.insert(descendant)
        }
    }

    /// Takes a layer out of its parent's child list, keeping the layer itself.
    @discardableResult
    public mutating func detach(_ id: LayerID) -> (parent: LayerParent, index: Int)? {
        guard let parent = document.parentRef(of: id) else { return nil }
        let index = document.childIDs(of: parent).firstIndex(of: id) ?? 0
        editChildren(of: parent) { $0.removeAll { $0 == id } }
        update(id) { $0.parent = nil }
        return (parent, index)
    }

    /// Puts a detached layer into `parent`; `index` counts from the bottom, nil puts it on top.
    public mutating func attach(_ id: LayerID, to parent: LayerParent, at index: Int? = nil) {
        editChildren(of: parent) { children in
            let position = min(max(index ?? children.count, 0), children.count)
            children.insert(id, at: position)
        }
        update(id) { layer in
            if case .layer(let parentID) = parent { layer.parent = parentID } else { layer.parent = nil }
        }
    }

    private mutating func editChildren(of parent: LayerParent, _ body: (inout [LayerID]) -> Void) {
        switch parent {
        case .page(let id): updatePage(id) { body(&$0.layers) }
        case .layer(let id): update(id) { body(&$0.children) }
        }
    }
}
