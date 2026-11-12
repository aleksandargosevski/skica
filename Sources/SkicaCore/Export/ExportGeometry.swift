import CoreGraphics
import Foundation

extension Style {
    /// How far painting reaches past the frame: outside and centered borders, drop shadows, blur.
    public var paintOutset: CGFloat {
        let border = borders.filter(\.isEnabled).map { $0.position == .inside ? 0 : $0.width }.max() ?? 0
        let shadow = shadows.filter(\.isEnabled).map { max(abs($0.x), abs($0.y)) + $0.blur * 1.5 + max($0.spread, 0) }.max() ?? 0
        let blurReach = blur.map { $0.isEnabled ? $0.radius * 3 : 0 } ?? 0
        return border + shadow + blurReach
    }
}

extension Document {
    /// What exporting a layer covers on the page: an artboard's frame (it clips its contents),
    /// otherwise everything the layer and its contents paint, rounded out to whole points.
    public func exportBounds(of id: LayerID) -> CGRect? {
        guard let layer = layers[id] else { return nil }
        if layer.isArtboard { return worldBounds(of: id) }
        return paintedBounds(of: id)?.integral
    }

    private func paintedBounds(of id: LayerID) -> CGRect? {
        guard let layer = layers[id], let own = worldBounds(of: id) else { return nil }
        let outset = layer.style.paintOutset
        var bounds = layer.kind == .group ? nil : own.insetBy(dx: -outset, dy: -outset)
        for child in layer.children where layers[child]?.isVisible == true {
            if let childBounds = paintedBounds(of: child) {
                bounds = bounds?.union(childBounds) ?? childBounds
            }
        }
        if layer.kind == .group, let painted = bounds, outset > 0 {
            bounds = painted.insetBy(dx: -outset, dy: -outset)
        }
        return bounds ?? own
    }

    /// The layers marked for export (with presets), in layer-list order, on every page.
    public var exportableLayers: [LayerID] {
        pages.flatMap(listOrder(of:)).filter { layers[$0]?.exports.isEmpty == false }
    }

    /// The top-level artboards of a page, left to right and top to bottom.
    public func artboards(on page: Page) -> [LayerID] {
        page.layers
            .filter { layers[$0]?.isArtboard == true }
            .sorted { lhs, rhs in
                let a = layers[lhs]!.frame
                let b = layers[rhs]!.frame
                return a.y != b.y ? a.y < b.y : a.x < b.x
            }
    }

    /// A file name for a layer: its name with path separators kept as folders, other characters
    /// that file systems reject replaced.
    public func exportName(of id: LayerID) -> String {
        let name = layers[id]?.name ?? "Layer"
        let parts = name.split(separator: "/").map { part in
            String(part).trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: ":", with: "-")
                .replacingOccurrences(of: "\\", with: "-")
        }.filter { !$0.isEmpty && $0 != "." && $0 != ".." }
        return parts.isEmpty ? "Layer" : parts.joined(separator: "/")
    }
}
