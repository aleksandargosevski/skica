import CoreGraphics
import Foundation

/// Vimium-style labels for picking layers with the keyboard.
public enum HintLabels {
    /// Home row first, then the rows above and below.
    public static let alphabet = Array("asdfghjklqwertyuiopzxcvbnm").map(String.init)

    /// One letter per target while that suffices, otherwise two letters for all, so no label
    /// is the start of another.
    public static func labels(count: Int) -> [String] {
        guard count > alphabet.count else { return Array(alphabet.prefix(count)) }
        let pairs = alphabet.flatMap { first in alphabet.map { first + $0 } }
        return Array(pairs.prefix(count))
    }

    /// The layers worth labeling, in reading order (top to bottom, then left to right): the
    /// level clicks select (top-level layers, artboards and their contents), plus the siblings
    /// of a selection inside a group. Only visible, unlocked layers within `area`.
    public static func targets(on page: Page, in document: Document, selection: [LayerID], area: CGRect) -> [LayerID] {
        var candidates: [LayerID] = []
        for id in page.layers {
            candidates.append(id)
            if document.layers[id]?.isArtboard == true { candidates += document.layers[id]?.children ?? [] }
        }
        for id in selection {
            if let parent = document.layers[id]?.parent, document.layers[parent]?.kind == .group {
                candidates += document.layers[parent]?.children ?? []
            }
        }
        var seen = Set<LayerID>()
        let visible = candidates.compactMap { id -> (LayerID, CGRect)? in
            guard seen.insert(id).inserted, let layer = document.layers[id], layer.isVisible, !layer.isLocked,
                  document.ancestors(of: id).allSatisfy({ document.layers[$0]?.isVisible == true }),
                  let bounds = document.worldBounds(of: id), bounds.intersects(area) else { return nil }
            return (id, bounds)
        }
        return visible
            .sorted { lhs, rhs in
                let rowL = (lhs.1.minY / 24).rounded(.down)
                let rowR = (rhs.1.minY / 24).rounded(.down)
                return rowL != rowR ? rowL < rowR : lhs.1.minX < rhs.1.minX
            }
            .map(\.0)
    }
}
