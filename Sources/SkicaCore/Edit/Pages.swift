import CoreGraphics
import Foundation

extension Transaction {
    /// Adds an empty page after `after` (or at the end) and returns it.
    @discardableResult
    public mutating func addPage(named name: String, after: PageID? = nil) -> PageID {
        let page = Page(name: name)
        var pages = document.pages
        let index = after.flatMap { id in pages.firstIndex { $0.id == id } }.map { $0 + 1 } ?? pages.count
        pages.insert(page, at: index)
        replacePages(pages)
        return page.id
    }

    /// Removes a page with everything on it; the last page cannot be removed.
    public mutating func removePage(_ id: PageID) {
        guard document.pages.count > 1, let page = document.page(id) else { return }
        for layer in page.layers { remove(layer) }
        replacePages(document.pages.filter { $0.id != id })
    }

    public mutating func renamePage(_ id: PageID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        updatePage(id) { $0.name = trimmed }
    }

    /// Moves layers onto another page, keeping where they are on the page.
    public mutating func move(_ ids: [LayerID], toPage pageID: PageID) {
        guard document.page(pageID) != nil else { return }
        for id in document.topmostOnly(ids) {
            reparent(id, to: .page(pageID))
        }
    }
}

extension Document {
    /// A name like "Page 3" that no page uses yet.
    public func nextPageName() -> String {
        let names = Set(pages.map(\.name))
        var number = pages.count + 1
        while names.contains("Page \(number)") { number += 1 }
        return "Page \(number)"
    }
}
