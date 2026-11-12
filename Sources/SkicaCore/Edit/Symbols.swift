import CoreGraphics
import Foundation

extension Document {
    /// The master layer of a symbol. Masters live at the top level of a page, like artboards.
    public func master(of symbolID: SymbolID) -> LayerID? {
        for page in pages {
            if let id = page.layers.first(where: { layers[$0]?.symbolID == symbolID }) { return id }
        }
        return nil
    }

    /// Every symbol master, in page and layer order.
    public var symbolMasters: [LayerID] {
        pages.flatMap { page in page.layers.filter { layers[$0]?.symbolID != nil } }
    }

    public func instances(of symbolID: SymbolID) -> [LayerID] {
        layers.values.filter { $0.symbolInstance?.symbolID == symbolID }.map(\.id)
    }

    /// Layers of a symbol an instance can change: text, filled shapes, images and nested
    /// instances, including those inside nested symbols, as (layer, depth) pairs.
    public func overridableLayers(of symbolID: SymbolID, depth: Int = 0) -> [(layer: Layer, depth: Int)] {
        guard depth < 6, let masterID = master(of: symbolID), let master = layers[masterID] else { return [] }
        var result: [(Layer, Int)] = []
        func visit(_ id: LayerID, level: Int) {
            guard let layer = layers[id] else { return }
            switch layer.kind {
            case .text, .image, .rectangle, .oval, .polygon, .star, .path:
                result.append((layer, level))
            case .symbolInstance(let instance):
                result.append((layer, level))
                result += overridableLayers(of: instance.symbolID, depth: depth + 1).map { ($0.layer, $0.depth + level + 1) }
            case .group:
                layer.children.reversed().forEach { visit($0, level: level) }
            case .artboard, .symbolMaster, .line:
                break
            }
        }
        master.children.reversed().forEach { visit($0, level: 0) }
        return result
    }
}

extension Transaction {
    /// Makes a symbol of the layers. An artboard on its own becomes a symbol in place; other
    /// layers move into a new master on the "Symbols" page and an instance takes their place.
    /// Returns the master and the instance (nil when an artboard was converted).
    @discardableResult
    public mutating func createSymbol(from ids: [LayerID], name: String) -> (master: LayerID, instance: LayerID?)? {
        let topmost = document.topmostOnly(ids)
        if topmost.count == 1, let only = topmost.first, document.layers[only]?.kind == .artboard, document.layers[only]?.parent == nil {
            update(only) { $0.kind = .symbolMaster(.make()) }
            return (only, nil)
        }
        guard let first = topmost.first, let parent = document.parentRef(of: first) else { return nil }
        let siblings = document.childIDs(of: parent)
        let members = siblings.filter { topmost.contains($0) && document.layers[$0]?.isArtboard == false }
        guard !members.isEmpty, let bounds = document.worldBounds(of: members)?.integral,
              let topIndex = members.compactMap(siblings.firstIndex(of:)).max() else { return nil }

        let symbolsPage = symbolsPageID()
        let right = document.page(symbolsPage).flatMap { document.contentBounds(of: $0) }.map { $0.maxX + 100 } ?? 0
        let symbolID = SymbolID.make()
        let master = Layer(name: name, kind: .symbolMaster(symbolID), frame: Rect(x: right, y: 0, width: bounds.width, height: bounds.height))
        insert(master, into: .page(symbolsPage))

        // Where the instance goes, in the coordinates of the layers' parent.
        let parentSpace = document.parentSpace(of: first)
        let instanceOrigin = bounds.origin.applying(parentSpace.inverted())
        let instance = Layer(name: name, kind: .symbolInstance(SymbolInstance(symbolID: symbolID)),
                             frame: Rect(x: instanceOrigin.x, y: instanceOrigin.y, width: bounds.width, height: bounds.height))
        insert(instance, into: parent, at: topIndex + 1)

        for member in members {
            guard let layer = document.layers[member] else { continue }
            let worldOrigin = CGPoint(x: layer.frame.x, y: layer.frame.y).applying(document.parentSpace(of: member))
            detach(member)
            attach(member, to: .layer(master.id))
            update(member) { layer in
                layer.frame.x = worldOrigin.x - bounds.minX
                layer.frame.y = worldOrigin.y - bounds.minY
            }
        }
        return (master.id, instance.id)
    }

    /// A new instance of a symbol at its master's size, centered on `center` (page coordinates).
    @discardableResult
    public mutating func insertInstance(of symbolID: SymbolID, centeredAt center: CGPoint, on pageID: PageID) -> LayerID? {
        guard let masterID = document.master(of: symbolID), let master = document.layers[masterID] else { return nil }
        let parentID = document.artboard(at: center, on: pageID)
        let space = parentID.map(document.contentsTransform(of:)) ?? .identity
        let local = center.applying(space.inverted())
        let frame = Rect(x: (local.x - master.frame.width / 2).rounded(), y: (local.y - master.frame.height / 2).rounded(),
                         width: master.frame.width, height: master.frame.height)
        let instance = Layer(name: master.name, kind: .symbolInstance(SymbolInstance(symbolID: symbolID)), frame: frame)
        insert(instance, into: parentID.map(LayerParent.layer) ?? .page(pageID))
        return instance.id
    }

    /// Replaces an instance with a group of copies of its symbol's layers, overrides applied.
    @discardableResult
    public mutating func detach(instance id: LayerID) -> LayerID? {
        guard let layer = document.layers[id], let instance = layer.symbolInstance,
              let masterID = document.master(of: instance.symbolID), let master = document.layers[masterID],
              let parent = document.parentRef(of: id), let index = document.childIDs(of: parent).firstIndex(of: id) else { return nil }
        let group = Layer(name: layer.name, kind: .group, frame: layer.frame, rotation: layer.rotation, opacity: layer.opacity,
                          isVisible: layer.isVisible, isLocked: layer.isLocked)
        remove(id)
        insert(group, into: parent, at: index)
        if master.style.fills.contains(where: \.isEnabled) {
            let background = Layer(name: "Background", kind: .rectangle(cornerRadius: 0),
                                   frame: Rect(x: 0, y: 0, width: layer.frame.width, height: layer.frame.height),
                                   style: Style(fills: master.style.fills))
            insert(background, into: .layer(group.id))
        }
        // The same layout the instance shows: constraints for the master's layers.
        let scope = SymbolScope.root.entering(instance, master: master, size: CGSizeValue(width: layer.frame.width, height: layer.frame.height), in: document)
        for child in master.children {
            copyDetached(child, into: group.id, overrides: instance.overrides, frame: scope?.frames[child], scaleX: 1, scaleY: 1)
        }
        return group.id
    }

    /// Copies a master's layer into a detached group; `frame` replaces its frame (from the
    /// instance's layout), and the scale stretches layers inside groups that changed size.
    private mutating func copyDetached(_ id: LayerID, into parent: LayerID, overrides: [LayerID: LayerOverride], frame: Rect?, scaleX: Double, scaleY: Double) {
        guard let original = document.layers[id] else { return }
        var copy = overrides[id]?.applied(to: original) ?? original
        let children = copy.children
        copy.id = .make()
        copy.frame = frame ?? Rect(x: copy.frame.x * scaleX, y: copy.frame.y * scaleY, width: copy.frame.width * scaleX, height: copy.frame.height * scaleY)
        if var nested = copy.symbolInstance {
            // Overrides meant for layers inside the nested symbol stay with it.
            nested.overrides = nested.overrides.merging(overrides) { _, outer in outer }
            copy.kind = .symbolInstance(nested)
        }
        insert(copy, into: .layer(parent))
        let innerScaleX = original.frame.width > 0 ? copy.frame.width / original.frame.width : 1
        let innerScaleY = original.frame.height > 0 ? copy.frame.height / original.frame.height : 1
        for child in children {
            copyDetached(child, into: copy.id, overrides: overrides, frame: nil,
                         scaleX: copy.kind == .group ? innerScaleX : 1, scaleY: copy.kind == .group ? innerScaleY : 1)
        }
    }

    /// Instances whose symbol is deleted turn into groups first, as in Sketch.
    public mutating func detachInstances(of symbolID: SymbolID) {
        for id in document.instances(of: symbolID) { detach(instance: id) }
    }

    public mutating func setOverride(_ layerID: LayerID, in instanceID: LayerID, _ body: (inout LayerOverride) -> Void) {
        update(instanceID) { layer in
            guard var instance = layer.symbolInstance else { return }
            var override = instance.overrides[layerID] ?? LayerOverride()
            body(&override)
            instance.overrides[layerID] = override.isEmpty ? nil : override
            layer.kind = .symbolInstance(instance)
        }
    }

    /// The page named "Symbols", added at the end when there is none.
    mutating func symbolsPageID() -> PageID {
        if let page = document.pages.first(where: { $0.name == "Symbols" }) { return page.id }
        return addPage(named: "Symbols")
    }
}
