import CoreGraphics
import Foundation

extension Transaction {
    /// Containers resized by this edit lay out their children: artboards and symbol masters by
    /// the children's constraints, groups by scaling them. Children that are containers and change
    /// size in turn lay out their own children.
    mutating func layoutResizedContainers() {
        var queue = touched.filter { id in
            guard let layer = document.layers[id], layer.isContainer, layer.stack == nil,
                  let before = original.layers[id] else { return false }
            return before.frame.width != layer.frame.width || before.frame.height != layer.frame.height
        }.map { id in (id, original.layers[id]!.frame) }

        while !queue.isEmpty {
            let (id, oldFrame) = queue.removeFirst()
            guard let layer = document.layers[id] else { continue }
            let old = CGSizeValue(width: oldFrame.width, height: oldFrame.height)
            let new = CGSizeValue(width: layer.frame.width, height: layer.frame.height)
            for child in layer.children {
                guard let current = document.layers[child] else { continue }
                let frame: Rect
                if layer.kind == .group {
                    frame = Constraints(horizontal: .scale, vertical: .scale).apply(to: current.frame, from: old, to: new)
                } else {
                    frame = current.constraints.apply(to: current.frame, from: old, to: new)
                }
                guard frame != current.frame else { continue }
                update(child) { $0.frame = frame }
                if current.isContainer, current.stack == nil, frame.width != current.frame.width || frame.height != current.frame.height {
                    queue.append((child, current.frame))
                }
            }
        }
    }

    /// Re-lays out every stack affected by this edit (its own changes or its children's), the
    /// deepest first so that growing children make their stacks grow.
    mutating func layoutStacks() {
        var pending = Set<LayerID>()
        for id in touched {
            guard let layer = document.layers[id] else { continue }
            if layer.stack != nil { pending.insert(id) }
            if let parent = layer.parent, document.layers[parent]?.stack != nil { pending.insert(parent) }
        }
        while let id = pending.max(by: { document.ancestors(of: $0).count < document.ancestors(of: $1).count }) {
            pending.remove(id)
            let before = document.layers[id]?.frame
            layoutStack(id)
            if let layer = document.layers[id], layer.frame != before, let parent = layer.parent, document.layers[parent]?.stack != nil {
                pending.insert(parent)
            }
        }
    }

    /// Places a stack's visible children one after another and, when it hugs, sizes it to them.
    mutating func layoutStack(_ id: LayerID) {
        guard let container = document.layers[id], let stack = container.stack else { return }
        let horizontal = stack.direction == .horizontal
        let children = container.children.compactMap { document.layers[$0] }.filter(\.isVisible)
        let padding = stack.padding
        let mainStart = horizontal ? padding.left : padding.top
        let crossStart = horizontal ? padding.top : padding.left
        let crossPadding = horizontal ? padding.top + padding.bottom : padding.left + padding.right
        let mainPadding = horizontal ? padding.left + padding.right : padding.top + padding.bottom

        let crossSizes = children.map { horizontal ? $0.frame.height : $0.frame.width }
        let mainSizes = children.map { horizontal ? $0.frame.width : $0.frame.height }
        let contentCross = crossSizes.max() ?? 0
        let contentMain = mainSizes.reduce(0, +) + stack.spacing * Double(max(children.count - 1, 0))
        let crossRoom = stack.hugsContents ? contentCross : (horizontal ? container.frame.height : container.frame.width) - crossPadding

        var position = mainStart
        for child in children {
            let main = horizontal ? child.frame.width : child.frame.height
            let cross = horizontal ? child.frame.height : child.frame.width
            let offset: Double = switch stack.alignment {
            case .start: 0
            case .center: ((crossRoom - cross) / 2).rounded()
            case .end: crossRoom - cross
            }
            let x = horizontal ? position : crossStart + offset
            let y = horizontal ? crossStart + offset : position
            if child.frame.x != x || child.frame.y != y {
                update(child.id) { layer in
                    layer.frame.x = x
                    layer.frame.y = y
                }
            }
            position += main + stack.spacing
        }

        guard stack.hugsContents else { return }
        let width = horizontal ? contentMain + mainPadding : contentCross + crossPadding
        let height = horizontal ? contentCross + crossPadding : contentMain + mainPadding
        if container.frame.width != width || container.frame.height != height {
            update(id) { layer in
                layer.frame.width = width
                layer.frame.height = height
            }
        }
    }

    /// Puts the layers into a new stack group (direction from how they are arranged), or turns
    /// a single container into a stack. Returns the stack.
    @discardableResult
    public mutating func addStack(_ ids: [LayerID]) -> LayerID? {
        let topmost = document.topmostOnly(ids)
        if topmost.count == 1, let only = topmost.first, let layer = document.layers[only], layer.isContainer {
            guard layer.stack == nil else { return only }
            let stack = Self.inferredStack(for: layer.children.compactMap { document.layers[$0] }, fixedSize: layer.isArtboard)
            update(only) { $0.stack = stack }
            layoutStack(only)
            return only
        }
        let members = topmost.compactMap { document.layers[$0] }
        // Order children along the stack the way they are arranged on the canvas.
        let stack = Self.inferredStack(for: members, fixedSize: false)
        guard let group = group(topmost, name: "Stack") else { return nil }
        let sorted = (document.layers[group]?.children ?? []).sorted { lhs, rhs in
            guard let a = document.layers[lhs]?.frame, let b = document.layers[rhs]?.frame else { return false }
            return stack.direction == .horizontal ? a.x < b.x : a.y < b.y
        }
        update(group) { layer in
            layer.children = sorted
            layer.stack = stack
        }
        layoutStack(group)
        return group
    }

    /// A stack that keeps the current arrangement close: row or column, the average gap, padding 0.
    private static func inferredStack(for layers: [Layer], fixedSize: Bool) -> StackLayout {
        guard layers.count > 1 else { return StackLayout(hugsContents: !fixedSize) }
        let xs = layers.map(\.frame.x)
        let ys = layers.map(\.frame.y)
        let horizontal = (xs.max()! - xs.min()!) >= (ys.max()! - ys.min()!)
        let sorted = layers.sorted { horizontal ? $0.frame.x < $1.frame.x : $0.frame.y < $1.frame.y }
        let gaps = zip(sorted, sorted.dropFirst()).map { a, b in
            horizontal ? b.frame.x - (a.frame.x + a.frame.width) : b.frame.y - (a.frame.y + a.frame.height)
        }
        let spacing = max((gaps.reduce(0, +) / Double(gaps.count)).rounded(), 0)
        return StackLayout(direction: horizontal ? .horizontal : .vertical, spacing: spacing, hugsContents: !fixedSize)
    }
}
