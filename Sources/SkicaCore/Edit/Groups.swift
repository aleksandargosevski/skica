import CoreGraphics
import Foundation

/// Grouping, and keeping group frames wrapped tightly around their children.
extension Transaction {
    /// Puts the layers (which must share a parent; others are left out) into a new group placed
    /// where the topmost of them was. Returns the group.
    @discardableResult
    public mutating func group(_ ids: [LayerID], name: String = "Group") -> LayerID? {
        let topmost = document.topmostOnly(ids)
        guard let first = topmost.first, let parent = document.parentRef(of: first) else { return nil }
        let siblings = document.childIDs(of: parent)
        let members = siblings.filter { topmost.contains($0) && document.layers[$0]?.isArtboard == false }
        guard !members.isEmpty, let bounds = boundsInParent(of: members),
              let topIndex = members.compactMap(siblings.firstIndex(of:)).max() else { return nil }

        let group = Layer(name: name, kind: .group, frame: Rect(bounds))
        insert(group, into: parent, at: topIndex + 1)
        for member in members {
            detach(member)
            attach(member, to: .layer(group.id))
            update(member) { layer in
                layer.frame.x -= bounds.minX
                layer.frame.y -= bounds.minY
            }
        }
        return group.id
    }

    /// Moves a group's children into its parent at the group's place, keeping how they look,
    /// and removes the group. Returns the children.
    @discardableResult
    public mutating func ungroup(_ id: LayerID) -> [LayerID] {
        guard let group = document.layers[id], group.kind == .group,
              let parent = document.parentRef(of: id),
              let index = document.childIDs(of: parent).firstIndex(of: id) else { return [] }
        let children = group.children
        let rotation = group.rotationTransform
        for (offset, child) in children.enumerated() {
            detach(child)
            attach(child, to: parent, at: index + offset)
            update(child) { layer in
                let size = CGSize(width: layer.frame.width, height: layer.frame.height)
                let center = CGPoint(x: layer.frame.x + group.frame.x + size.width / 2, y: layer.frame.y + group.frame.y + size.height / 2)
                    .applying(rotation)
                layer.frame.x = center.x - size.width / 2
                layer.frame.y = center.y - size.height / 2
                layer.rotation = (layer.rotation + group.rotation).truncatingRemainder(dividingBy: 360)
                layer.opacity *= group.opacity
            }
        }
        remove(id)
        return children
    }

    /// Wraps every group affected by this transaction tightly around its children (deepest
    /// first), and removes groups left empty. Called before an edit is committed.
    public mutating func fitGroups() {
        let affected = touched.flatMap { id -> [LayerID] in
            [id] + (document.layers[id].map { _ in document.ancestors(of: id) } ?? originalAncestors(of: id))
        }
        let groups = Set(affected).filter { document.layers[$0]?.kind == .group }
        let deepestFirst = groups.sorted { document.ancestors(of: $0).count > document.ancestors(of: $1).count }
        for id in deepestFirst {
            fit(id)
        }
    }

    private mutating func fit(_ id: LayerID) {
        guard let group = document.layers[id] else { return }
        if group.children.isEmpty {
            remove(id)
            return
        }
        // Stacks size themselves (padding included).
        guard group.rotation == 0, group.stack == nil, let bounds = boundsInParent(of: group.children) else { return }
        guard bounds != CGRect(x: 0, y: 0, width: group.frame.width, height: group.frame.height) else { return }
        for child in group.children {
            update(child) { layer in
                layer.frame.x -= bounds.minX
                layer.frame.y -= bounds.minY
            }
        }
        update(id) { layer in
            layer.frame = Rect(x: layer.frame.x + bounds.minX, y: layer.frame.y + bounds.minY, width: bounds.width, height: bounds.height)
        }
    }

    /// Bounds of the layers (as drawn, including rotation) in their parent's coordinates.
    private func boundsInParent(of ids: [LayerID]) -> CGRect? {
        ids.compactMap { id in document.layers[id].map { $0.frame.cgRect.applying($0.rotationTransform) } }
            .reduce(nil) { union, rect in union?.union(rect) ?? rect }
    }

    /// For layers removed in this transaction, their ancestors before the edit.
    private func originalAncestors(of id: LayerID) -> [LayerID] {
        original.ancestors(of: id).filter { document.layers[$0] != nil }
    }
}
