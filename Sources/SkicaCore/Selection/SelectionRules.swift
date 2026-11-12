import CoreGraphics
import Foundation

/// How clicks, marquees and the keyboard choose layers.
public enum SelectionRules {
    /// The layer a click selects, given the hit path from `HitTester`.
    ///
    /// Artboards are transparent to clicks (they are selected by their title), so a click picks
    /// the outermost layer inside them, unless the current selection is deeper (e.g. inside a
    /// group), in which case the click stays at that level. `deep` (⌘-click) picks the deepest layer.
    public static func clickTarget(path: [LayerID], in document: Document, selection: [LayerID], deep: Bool) -> LayerID? {
        let candidates = path.filter { document.layers[$0]?.isArtboard == false }
        if deep { return candidates.last }
        let selectedParents = Set(selection.map { document.layers[$0]?.parent })
        return candidates.last { selectedParents.contains(document.layers[$0]?.parent) && !isTopLevelOrArtboardChild($0, document) }
            ?? candidates.first
    }

    /// A double-click goes one level deeper than the selection along the hit path (into a group).
    public static func doubleClickTarget(path: [LayerID], in document: Document, selection: [LayerID]) -> LayerID? {
        if let selected = selection.first, let index = path.firstIndex(of: selected), index + 1 < path.count {
            return path[index + 1]
        }
        return clickTarget(path: path, in: document, selection: selection, deep: false)
    }

    /// Layers touched by a marquee: whole artboards it fully covers, otherwise the layers inside
    /// artboards and top-level layers it intersects.
    public static func marquee(_ rect: CGRect, on page: Page, in document: Document) -> [LayerID] {
        var result: [LayerID] = []
        for id in page.layers {
            guard let layer = document.layers[id], layer.isVisible, !layer.isLocked,
                  let bounds = document.worldBounds(of: id) else { continue }
            if layer.isArtboard {
                if rect.contains(bounds) {
                    result.append(id)
                } else if rect.intersects(bounds) {
                    result += layer.children.filter { child in
                        guard let childLayer = document.layers[child], childLayer.isVisible, !childLayer.isLocked else { return false }
                        return document.worldBounds(of: child)?.intersects(rect) == true
                    }
                }
            } else if rect.intersects(bounds) {
                result.append(id)
            }
        }
        return result
    }

    /// The next layer in layer-list order among the siblings of `id` (topmost first), wrapping around.
    public static func sibling(of id: LayerID, in document: Document, forward: Bool) -> LayerID? {
        guard let parent = document.parentRef(of: id) else { return nil }
        let list = Array(document.childIDs(of: parent).reversed())
        guard let index = list.firstIndex(of: id), list.count > 1 else { return nil }
        let next = forward ? (index + 1) % list.count : (index - 1 + list.count) % list.count
        return list[next]
    }

    /// The topmost child of a container.
    public static func firstChild(of id: LayerID, in document: Document) -> LayerID? {
        document.layers[id]?.children.last
    }

    private static func isTopLevelOrArtboardChild(_ id: LayerID, _ document: Document) -> Bool {
        guard let parent = document.layers[id]?.parent else { return true }
        return document.layers[parent]?.isArtboard == true
    }
}
