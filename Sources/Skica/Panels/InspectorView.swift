import AppKit
import SkicaCore
import SwiftUI

/// Properties of the selected layers. Fields accept arithmetic (`100/3`, `+20`, `*2`);
/// ↑/↓ change the value by 1 (10 with shift), ↩ or ⇥ apply it, esc returns to the canvas.
struct InspectorView: View {
    let editor: DocumentEditor
    let textActions: TextActions
    let exportSelection: () -> Void
    let editPoints: () -> Void
    let perform: (CommandID) -> Void

    var body: some View {
        let _ = editor.revision
        let layers = editor.selectedLayers
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if layers.isEmpty {
                    emptyState.padding(16)
                    DocumentAssetsView(editor: editor)
                } else {
                    header(layers)
                    if !(layers.count == 1 && layers[0].parent == nil) {
                        AlignSection(editor: editor, layers: layers, perform: perform)
                    }
                    if layers.count == 1, layers[0].symbolInstance != nil {
                        SymbolSection(editor: editor, instance: layers[0], perform: perform)
                    }
                    if layers.allSatisfy({ ($0.textContent != nil) == (layers[0].textContent != nil) && (!$0.isContainer || $0.isArtboard) && $0.symbolInstance == nil }) {
                        InspectorSection { SharedStyleRow(editor: editor, layers: layers, perform: perform) }
                    }
                    InspectorSection { geometry(layers) }
                    if layers.allSatisfy({ $0.isContainer && $0.symbolInstance == nil }) {
                        StackSection(editor: editor, layers: layers)
                    }
                    if layers.allSatisfy({ layer in layer.parent.flatMap { editor.document.layers[$0] }?.isArtboard == true }) {
                        ConstraintsSection(editor: editor, layers: layers)
                    }
                    if let shape = shape(layers) {
                        InspectorSection { shape }
                    }
                    if layers.allSatisfy({ $0.vectorPath != nil }) {
                        PathSection(editor: editor, layers: layers, editPoints: editPoints)
                    }
                    if layers.allSatisfy({ $0.textContent != nil }) {
                        TextSection(layers: layers, actions: textActions)
                    }
                    let shapes = layers.allSatisfy { !$0.isContainer && $0.textContent == nil && $0.symbolInstance == nil }
                    let lines = layers.allSatisfy { ShapePath.isOpen($0.kind) }
                    let images = layers.allSatisfy { $0.imageHash != nil }
                    if images {
                        ImageSection(editor: editor, layers: layers, crop: editPoints)
                    }
                    if (shapes && !lines && !images) || layers.allSatisfy(\.isArtboard) {
                        FillsSection(editor: editor, layers: layers)
                    }
                    if shapes {
                        BordersSection(editor: editor, layers: layers)
                        ShadowsSection(title: "Shadow", editor: editor, layers: layers, items: \.shadows)
                    }
                    if shapes && !lines {
                        ShadowsSection(title: "Inner Shadow", editor: editor, layers: layers, items: \.innerShadows)
                    }
                    EffectsSection(editor: editor, layers: layers)
                    ExportSection(editor: editor, layers: layers, export: exportSelection)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No Selection").font(.system(size: 13, weight: .semibold))
            Text("Press R, O, L, Y, *, T or A, then drag on the canvas or press ↩. I adds an image.\n\nF labels layers to pick by keyboard, : opens the command line, ⌘P finds any command, layer or page, ? lists all shortcuts.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func header(_ layers: [Layer]) -> some View {
        HStack(spacing: 8) {
            Image(systemName: layers.count == 1 ? layers[0].symbolName : "square.on.square")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .background(SwiftUI.Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 1) {
                Text(layers.count == 1 ? layers[0].name : "\(layers.count) Layers")
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(subtitle(layers))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    /// The kind, and the artboard or group the layers are in, e.g. "Rectangle in Desktop".
    private func subtitle(_ layers: [Layer]) -> String {
        let kinds = Set(layers.map(\.typeTitle))
        let kind = kinds.count == 1 ? kinds.first ?? "" : "Mixed"
        let parents = Set(layers.map(\.parent))
        guard parents.count == 1, let parent = parents.first ?? nil,
              let name = editor.document.layers[parent]?.name else { return kind }
        return "\(kind) in \(name)"
    }

    private func geometry(_ layers: [Layer]) -> some View {
        Grid(horizontalSpacing: 8, verticalSpacing: 8) {
            GridRow {
                field(.text("X"), "Position X", layers, \.frame.x) { $0.frame.x = $1 }
                field(.text("Y"), "Position Y", layers, \.frame.y) { $0.frame.y = $1 }
            }
            GridRow {
                field(.text("W"), "Width", layers, \.frame.width, minimum: 0) { $0.frame.width = $1 }
                field(.text("H"), "Height", layers, \.frame.height, minimum: 0) { $0.frame.height = $1 }
            }
            GridRow {
                field(.symbol("rotate.right"), "Rotation", layers, \.rotation, suffix: "°") { $0.rotation = $1.truncatingRemainder(dividingBy: 360) }
                NumberField(.symbol("circle.lefthalf.filled"), help: "Opacity", value: common(layers) { $0.opacity * 100 }, minimum: 0, maximum: 100, suffix: "%") { value in
                    editor.updateSelection("Change Opacity", coalescingKey: "opacity") { $0.opacity = value / 100 }
                }
            }
        }
    }

    private func shape(_ layers: [Layer]) -> AnyView? {
        let kinds = layers.map(\.kind)
        if layers.allSatisfy(\.isArtboard) {
            let current = ArtboardPreset.all.first { preset in
                layers.allSatisfy { $0.frame.width == preset.width && $0.frame.height == preset.height }
            }
            return AnyView(MenuField(prefix: .symbol("rectangle.dashed"), title: current?.name ?? "Custom Size",
                                     options: ArtboardPreset.all.map { "\($0.name)  \(Int($0.width))×\(Int($0.height))" }) { choice in
                guard let preset = ArtboardPreset.all.first(where: { choice.hasPrefix($0.name + "  ") }) else { return }
                editor.updateSelection("Change Artboard Size") { layer in
                    layer.frame.width = preset.width
                    layer.frame.height = preset.height
                }
            })
        }
        if kinds.allSatisfy({ if case .rectangle = $0 { true } else { false } }) {
            return AnyView(Grid(horizontalSpacing: 8) {
                GridRow {
                    NumberField(.symbol("square.dashed"), help: "Corner radius", value: common(layers) { $0.cornerRadius ?? 0 }, minimum: 0) { value in
                        editor.updateSelection("Change Radius", coalescingKey: "radius") { $0.kind = .rectangle(cornerRadius: value) }
                    }
                    SwiftUI.Color.clear.frame(height: 1)
                }
            })
        }
        if kinds.allSatisfy({ if case .polygon = $0 { true } else { false } }) {
            return AnyView(Grid(horizontalSpacing: 8) {
                GridRow {
                    NumberField(.symbol("pentagon"), help: "Sides", value: common(layers) { Double($0.sides ?? 5) }, minimum: 3, maximum: 64) { value in
                        editor.updateSelection("Change Sides", coalescingKey: "sides") { $0.kind = .polygon(sides: Int(value.rounded())) }
                    }
                    SwiftUI.Color.clear.frame(height: 1)
                }
            })
        }
        if kinds.allSatisfy({ if case .star = $0 { true } else { false } }) {
            return AnyView(Grid(horizontalSpacing: 8) {
                GridRow {
                    NumberField(.symbol("star"), help: "Points", value: common(layers) { Double($0.starShape?.points ?? 5) }, minimum: 3, maximum: 64) { value in
                        editor.updateSelection("Change Points", coalescingKey: "points") { layer in
                            layer.kind = .star(points: Int(value.rounded()), innerRadius: layer.starShape?.innerRadius ?? 0.5)
                        }
                    }
                    NumberField(.symbol("circle.dotted"), help: "Inner radius", value: common(layers) { ($0.starShape?.innerRadius ?? 0.5) * 100 }, minimum: 1, maximum: 100, suffix: "%") { value in
                        editor.updateSelection("Change Inner Radius", coalescingKey: "inner") { layer in
                            layer.kind = .star(points: layer.starShape?.points ?? 5, innerRadius: value / 100)
                        }
                    }
                }
            })
        }
        return nil
    }

    private func field(_ prefix: FieldPrefix, _ help: String, _ layers: [Layer], _ keyPath: KeyPath<Layer, Double>,
                       minimum: Double? = nil, suffix: String? = nil, apply: @escaping (inout Layer, Double) -> Void) -> NumberField {
        NumberField(prefix, help: help, value: common(layers) { $0[keyPath: keyPath] }, minimum: minimum, suffix: suffix) { value in
            editor.updateSelection("Change \(help)", coalescingKey: help) { apply(&$0, value) }
        }
    }
}

/// Paths: how overlapping parts fill, and the way into point editing.
private struct PathSection: View {
    let editor: DocumentEditor
    let layers: [Layer]
    let editPoints: () -> Void

    var body: some View {
        let rules = Set(layers.compactMap { $0.vectorPath?.fillRule })
        let points = layers.compactMap { $0.vectorPath?.pointRefs.count }.reduce(0, +)
        InspectorSection(title: "Path") {
            HStack(spacing: 6) {
                MenuField(prefix: .symbol("circle.circle"), title: rules.count == 1 ? (rules.first == .evenOdd ? "Even-Odd" : "Non-Zero") : "Mixed",
                          options: ["Non-Zero", "Even-Odd"]) { choice in
                    editor.updateSelection("Change Fill Rule") { layer in
                        guard var vector = layer.vectorPath else { return }
                        vector.fillRule = choice == "Even-Odd" ? .evenOdd : .nonZero
                        layer.kind = .path(vector)
                    }
                }
                Button(action: editPoints) {
                    Text("Edit \(points) Points  E")
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 10)
                        .frame(height: 26)
                        .background(SwiftUI.Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .disabled(layers.count != 1)
            }
        }
    }
}

/// Image layers: their natural size, and a way back to it.
private struct ImageSection: View {
    let editor: DocumentEditor
    let layers: [Layer]
    /// Starts cropping on the canvas (`e`).
    let crop: () -> Void

    var body: some View {
        let sizes = layers.compactMap { layer in layer.imageHash.flatMap { editor.document.images[$0] }.flatMap(ImageData.naturalSize(of:)) }
        InspectorSection(title: "Image") {
            HStack {
                if sizes.count == 1, let size = sizes.first {
                    Text("\(Int(size.width)) × \(Int(size.height)) pt original")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Original Size") {
                    editor.perform("Original Size") { transaction in
                        for layer in layers {
                            guard let size = layer.imageHash.flatMap({ transaction.document.images[$0] }).flatMap(ImageData.naturalSize(of:)) else { continue }
                            transaction.update(layer.id) { layer in
                                layer.frame.width = size.width
                                layer.frame.height = size.height
                                layer.imageCrop = nil
                            }
                        }
                    }
                }
                .controlSize(.small)
            }
            HStack {
                if layers.count == 1 {
                    Button("Crop") { crop() }
                        .help("Crop the image on the canvas (E or double-click)")
                }
                if layers.contains(where: { $0.imageCrop != nil }) {
                    Button("Reset Crop") { editor.perform("Reset Crop") { $0.resetCrop(layers.map(\.id)) } }
                        .help("Show the whole image again")
                }
                Spacer()
            }
            .controlSize(.small)
        }
    }
}

/// The shared value of all layers, or nil when they differ.
func common(_ layers: [Layer], _ value: (Layer) -> Double) -> Double? {
    guard let first = layers.first.map(value) else { return nil }
    return layers.dropFirst().allSatisfy { abs(value($0) - first) < 0.0001 } ? first : nil
}

/// A block of the inspector with an optional title and add button, separated by a hairline.
struct InspectorSection<Content: View>: View {
    var title: String?
    var onAdd: (() -> Void)?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                HStack {
                    Text(title)
                        .font(.system(size: 11, weight: .semibold))
                    Spacer()
                    if let onAdd {
                        IconButton(symbol: "plus", help: "Add \(title.lowercased())", action: onAdd)
                    }
                }
                .frame(height: 22)
            }
            content
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .overlay(alignment: .top) { Divider() }
    }
}

/// One fill, border or shadow: swatch, hex and opacity, show/hide and remove, then extra controls.
struct PaintRow<Extra: View>: View {
    let color: SkicaCore.Color
    let isEnabled: Bool
    /// Overrides the swatch's look, e.g. with a gradient preview.
    var swatch: AnyShapeStyle?
    /// Shown instead of the hex code when the color is not a single one (gradients).
    var caption: String?
    /// An extra button before show/hide, e.g. the fill type menu.
    var accessory: AnyView?
    /// The flag is true for continuous changes from the color panel, so they merge into one undo step.
    let onColor: (SkicaCore.Color, Bool) -> Void
    let onToggle: () -> Void
    let onRemove: () -> Void
    @ViewBuilder var extra: Extra

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                HStack(spacing: 6) {
                    ColorSwatch(color: color, style: swatch) { onColor($0, true) }
                    if let caption {
                        FieldBox(prefix: nil, isFocused: false) {
                            Text(caption).font(.system(size: 11)).foregroundStyle(.secondary)
                            Spacer(minLength: 0)
                        }
                    } else {
                        HexField(color: color) { onColor($0, false) }
                    }
                }
                .opacity(isEnabled ? 1 : 0.45)
                if let accessory { accessory }
                IconButton(symbol: isEnabled ? "eye" : "eye.slash", help: isEnabled ? "Hide" : "Show", action: onToggle)
                IconButton(symbol: "minus", help: "Remove", action: onRemove)
            }
            // Extra controls line up under the hex field.
            extra
                .padding(.leading, 32)
                .opacity(isEnabled ? 1 : 0.45)
        }
    }
}

extension Layer {
    var cornerRadius: Double? {
        if case .rectangle(let radius) = kind { return radius }
        return nil
    }

    var sides: Int? {
        if case .polygon(let sides) = kind { return sides }
        return nil
    }

    var starShape: (points: Int, innerRadius: Double)? {
        if case .star(let points, let innerRadius) = kind { return (points, innerRadius) }
        return nil
    }
}

extension LayerKind {
    var symbolName: String {
        switch self {
        case .artboard: "rectangle.dashed"
        case .symbolMaster: "diamond"
        case .symbolInstance: "diamond.fill"
        case .group: "folder"
        case .rectangle: "rectangle"
        case .oval: "circle"
        case .line: "line.diagonal"
        case .polygon: "pentagon"
        case .star: "star"
        case .path: "point.topleft.down.to.point.bottomright.curvepath"
        case .text: "textformat"
        case .image: "photo"
        }
    }
}
