import CoreGraphics
import Foundation

/// Where a layer lives: directly on a page, or inside a container layer.
public enum LayerParent: Hashable, Sendable {
    case page(PageID)
    case layer(LayerID)
}

extension Document {
    /// Children of a page or container, bottom to top.
    public func childIDs(of parent: LayerParent) -> [LayerID] {
        switch parent {
        case .page(let id): page(id)?.layers ?? []
        case .layer(let id): layers[id]?.children ?? []
        }
    }

    public func parentRef(of id: LayerID) -> LayerParent? {
        if let parent = layers[id]?.parent { return .layer(parent) }
        return pages.first { $0.layers.contains(id) }.map { .page($0.id) }
    }

    /// The page that shows the layer.
    public func pageID(of id: LayerID) -> PageID? {
        var current = id
        while let parent = layers[current]?.parent { current = parent }
        return pages.first { $0.layers.contains(current) }?.id
    }

    /// Ancestors from the top-level layer down to the direct parent.
    public func ancestors(of id: LayerID) -> [LayerID] {
        var result: [LayerID] = []
        var current = layers[id]?.parent
        while let parent = current {
            result.insert(parent, at: 0)
            current = layers[parent]?.parent
        }
        return result
    }

    public func isAncestor(_ ancestor: LayerID, of id: LayerID) -> Bool {
        ancestors(of: id).contains(ancestor)
    }

    /// The layer and all its descendants, parents before children.
    public func subtree(of id: LayerID) -> [LayerID] {
        guard let layer = layers[id] else { return [] }
        return [id] + layer.children.flatMap(subtree(of:))
    }

    /// Drops layers whose ancestor is also in the list, so an operation applies once per subtree.
    public func topmostOnly(_ ids: [LayerID]) -> [LayerID] {
        let set = Set(ids)
        return ids.filter { id in !ancestors(of: id).contains(where: set.contains) }
    }

    /// The topmost visible artboard on the page whose frame contains `point`.
    public func artboard(at point: CGPoint, on pageID: PageID) -> LayerID? {
        guard let page = page(pageID) else { return nil }
        return page.layers.reversed().first { id in
            guard let layer = layers[id], layer.isArtboard, layer.isVisible else { return false }
            return worldBounds(of: id)?.contains(point) == true
        }
    }

    /// Layers of the page in layer-list order: topmost first, children right after their parent.
    public func listOrder(of page: Page) -> [LayerID] {
        func visit(_ id: LayerID) -> [LayerID] {
            [id] + (layers[id]?.children.reversed().flatMap(visit) ?? [])
        }
        return page.layers.reversed().flatMap(visit)
    }
}
