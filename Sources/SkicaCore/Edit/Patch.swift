import Foundation

/// The difference between two documents: each changed layer before and after (nil when it
/// did not exist), and the page list when it changed. Undo applies the inverse.
public struct Patch: Equatable, Sendable {
    public var layers: [LayerID: LayerChange]
    public var pages: PagesChange?
    /// Shared styles and swatches before and after, when they changed.
    public var assets: AssetsChange?

    public init(layers: [LayerID: LayerChange] = [:], pages: PagesChange? = nil, assets: AssetsChange? = nil) {
        self.layers = layers
        self.pages = pages
        self.assets = assets
    }

    public var isEmpty: Bool { layers.isEmpty && pages == nil && assets == nil }

    public var inverse: Patch {
        Patch(
            layers: layers.mapValues { LayerChange(before: $0.after, after: $0.before) },
            pages: pages.map { PagesChange(before: $0.after, after: $0.before) },
            assets: assets.map { AssetsChange(before: $0.after, after: $0.before) }
        )
    }

    /// This patch followed by `later`, as one change.
    public func then(_ later: Patch) -> Patch {
        var merged = layers
        for (id, change) in later.layers {
            merged[id] = LayerChange(before: merged[id]?.before ?? change.before, after: change.after)
        }
        let pagesChange: PagesChange?
        switch (pages, later.pages) {
        case (nil, nil): pagesChange = nil
        case (let first?, nil): pagesChange = first
        case (nil, let second?): pagesChange = second
        case (let first?, let second?): pagesChange = PagesChange(before: first.before, after: second.after)
        }
        let assetsChange: AssetsChange?
        switch (assets, later.assets) {
        case (nil, nil): assetsChange = nil
        case (let first?, nil): assetsChange = first
        case (nil, let second?): assetsChange = second
        case (let first?, let second?): assetsChange = AssetsChange(before: first.before, after: second.after)
        }
        return Patch(
            layers: merged.filter { $0.value.before != $0.value.after },
            pages: pagesChange.flatMap { $0.before == $0.after ? nil : $0 },
            assets: assetsChange.flatMap { $0.before == $0.after ? nil : $0 }
        )
    }

    /// True when layers were added, removed or reordered, not only edited.
    public var changesStructure: Bool {
        pages != nil || layers.values.contains { change in
            guard let before = change.before, let after = change.after else { return true }
            return before.children != after.children || before.parent != after.parent
        }
    }
}

public struct LayerChange: Equatable, Sendable {
    public var before: Layer?
    public var after: Layer?

    public init(before: Layer?, after: Layer?) {
        self.before = before
        self.after = after
    }
}

public struct AssetsChange: Equatable, Sendable {
    public var before: DocumentAssets
    public var after: DocumentAssets

    public init(before: DocumentAssets, after: DocumentAssets) {
        self.before = before
        self.after = after
    }
}

public struct PagesChange: Equatable, Sendable {
    public var before: [Page]
    public var after: [Page]

    public init(before: [Page], after: [Page]) {
        self.before = before
        self.after = after
    }
}

extension Document {
    public mutating func apply(_ patch: Patch) {
        for (id, change) in patch.layers {
            layers[id] = change.after
        }
        if let pages = patch.pages {
            self.pages = pages.after
        }
        if let assets = patch.assets {
            self.assets = assets.after
        }
    }
}
