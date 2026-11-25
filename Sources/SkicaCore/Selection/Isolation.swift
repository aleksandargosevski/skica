import Foundation

/// "Show only the selection": a view-only state that hides every other layer on the page
/// without touching the document. Layers added later stay visible.
public struct Isolation: Equatable, Sendable {
    /// The topmost layers hidden while isolating; their contents are hidden with them.
    public let hidden: Set<LayerID>

    /// Hides everything on `page` except `kept`, their contents and the containers they are in.
    public init(keeping kept: [LayerID], on page: Page, in document: Document) {
        let keptSet = Set(kept)
        let containers = Set(kept.flatMap(document.ancestors(of:)))
        var hidden = Set<LayerID>()
        func visit(_ ids: [LayerID]) {
            for id in ids where !keptSet.contains(id) {
                if containers.contains(id) {
                    visit(document.layers[id]?.children ?? [])
                } else {
                    hidden.insert(id)
                }
            }
        }
        visit(page.layers)
        self.hidden = hidden
    }

    /// Whether `id` is hidden by the isolation, directly or through a hidden container.
    public func hides(_ id: LayerID, in document: Document) -> Bool {
        hidden.contains(id) || document.ancestors(of: id).contains(where: hidden.contains)
    }

    /// A copy of `document` to draw and hit test, with the isolated-away layers hidden.
    public func apply(to document: Document) -> Document {
        var shown = document
        for id in hidden { shown.layers[id]?.isVisible = false }
        return shown
    }
}
