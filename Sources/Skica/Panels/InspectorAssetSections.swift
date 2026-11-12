import SkicaCore
import SwiftUI

/// The selected instance's symbol and its overrides.
struct SymbolSection: View {
    let editor: DocumentEditor
    let instance: Layer
    let perform: (CommandID) -> Void

    var body: some View {
        // The document is not observed directly; reading the revision redraws on every change.
        let _ = editor.revision
        let document = editor.document
        let symbolID = instance.symbolInstance?.symbolID
        let master = symbolID.flatMap(document.master(of:)).flatMap { document.layers[$0] }
        let overrides = instance.symbolInstance?.overrides ?? [:]
        InspectorSection(title: "Symbol") {
            HStack(spacing: 6) {
                MenuField(prefix: .symbol("diamond"), title: master?.name ?? "Missing Symbol", options: symbolNames(document)) { name in
                    if let target = symbol(named: name, in: document) { editor.swapSymbol(to: target) }
                }
                IconButton(symbol: "arrow.up.forward.square", help: "Go to master (g s)") { perform(.goToMaster) }
                IconButton(symbol: "diamond.bottomhalf.filled", help: "Detach (⌥⌘B)") { perform(.detachSymbol) }
            }
            if let symbolID {
                let layers = document.overridableLayers(of: symbolID)
                if !layers.isEmpty {
                    HStack {
                        Text("Overrides").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                        Spacer()
                        if !overrides.isEmpty {
                            Button("Reset") { editor.resetOverrides() }
                                .buttonStyle(.borderless)
                                .font(.system(size: 11))
                        }
                    }
                    ForEach(layers, id: \.layer.id) { entry in
                        OverrideRow(editor: editor, layer: entry.layer, depth: entry.depth, override: overrides[entry.layer.id])
                    }
                }
            }
        }
    }

    private func symbolNames(_ document: Document) -> [String] {
        document.symbolMasters.compactMap { document.layers[$0]?.name }
    }

    private func symbol(named name: String, in document: Document) -> SymbolID? {
        document.symbolMasters.compactMap { document.layers[$0] }.first { $0.name == name }?.symbolID
    }
}

/// One overridable layer: its text, color, nested symbol and visibility for this instance.
private struct OverrideRow: View {
    let editor: DocumentEditor
    let layer: Layer
    let depth: Int
    let override: LayerOverride?

    @State private var text = ""
    @State private var isFocused = false

    var body: some View {
        let _ = editor.revision
        let visible = override?.isVisible ?? layer.isVisible
        HStack(spacing: 6) {
            Image(systemName: layer.kind.symbolName)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .frame(width: 14)
                .padding(.leading, CGFloat(depth) * 10)
            control
                .opacity(visible ? 1 : 0.45)
            IconButton(symbol: visible ? "eye" : "eye.slash", help: visible ? "Hide in this instance" : "Show in this instance") {
                editor.setOverride(layer.id) { $0.isVisible = visible == layer.isVisible ? !visible : nil }
            }
        }
    }

    @ViewBuilder
    private var control: some View {
        switch layer.kind {
        case .text(let content):
            FieldBox(prefix: nil, isFocused: isFocused) {
                KeyTextField(text: $text, placeholder: content.string, font: .systemFont(ofSize: 11), isBordered: false,
                             onSubmit: commitText, onEndEditing: commitText, onTab: commitText, onFocusChange: { isFocused = $0 })
            }
            .help(layer.name)
            .onAppear { text = override?.text ?? "" }
            .onChange(of: override?.text) { text = override?.text ?? "" }
        case .symbolInstance(let nested):
            let document = editor.document
            let current = override?.symbolID ?? nested.symbolID
            MenuField(prefix: nil, title: document.master(of: current).flatMap { document.layers[$0]?.name } ?? "Missing",
                      options: document.symbolMasters.compactMap { document.layers[$0]?.name }) { name in
                let target = document.symbolMasters.compactMap { document.layers[$0] }.first { $0.name == name }?.symbolID
                editor.setOverride(layer.id) { $0.symbolID = target == nested.symbolID ? nil : target }
            }
        case .image:
            Text(layer.name).font(.system(size: 11)).lineLimit(1)
            Spacer(minLength: 0)
        default:
            let base = layer.style.fills.first?.color ?? .black
            ColorSwatch(color: override?.color ?? base) { color in
                editor.setOverride(layer.id, coalescingKey: "override-\(layer.id)") { $0.color = color }
            }
            Text(layer.name).font(.system(size: 11)).lineLimit(1)
            Spacer(minLength: 0)
            if override?.color != nil {
                IconButton(symbol: "arrow.uturn.backward", help: "Use the symbol's color") {
                    editor.setOverride(layer.id) { $0.color = nil }
                }
            }
        }
    }

    private func commitText() {
        let newValue: String? = text.isEmpty ? nil : text
        guard newValue != override?.text else { return }
        editor.setOverride(layer.id) { $0.text = newValue }
    }
}

/// The shared style of the selected layers: which one, whether it was changed, what to do with it.
struct SharedStyleRow: View {
    let editor: DocumentEditor
    let layers: [Layer]
    let perform: (CommandID) -> Void

    private static let none = "No Shared Style"
    private static let create = "Create Style from Layer…"
    private static let update = "Update Style from Layer"
    private static let reset = "Reset to Style"
    private static let detach = "Detach from Style"

    var body: some View {
        let _ = editor.revision
        let document = editor.document
        let ids = Set(layers.map(\.sharedStyleID))
        let current = ids.count == 1 ? ids.first.flatMap { $0 }.flatMap(document.assets.sharedStyle) : nil
        let modified = layers.contains { document.isOutOfSync($0.id) }
        let wantsText = layers.allSatisfy { $0.textContent != nil }
        let styles = document.assets.sharedStyles.filter { $0.isTextStyle == wantsText }
        let title = ids.count > 1 ? "Mixed" : current.map { $0.name + (modified ? "  • modified" : "") } ?? Self.none
        let actions = current == nil ? [Self.create] : (modified ? [Self.update, Self.reset, Self.detach] : [Self.detach, Self.create])
        MenuField(prefix: .symbol("paintpalette"), title: title, options: styles.map(\.name) + actions) { choice in
            switch choice {
            case Self.create: perform(.createSharedStyle)
            case Self.update: perform(.updateSharedStyle)
            case Self.reset: perform(.resetToSharedStyle)
            case Self.detach: perform(.detachSharedStyle)
            default:
                if let style = styles.first(where: { $0.name == choice }) { editor.applySharedStyle(style.id) }
            }
        }
    }
}

/// With nothing selected: the document's palette and shared styles.
struct DocumentAssetsView: View {
    let editor: DocumentEditor

    var body: some View {
        let _ = editor.revision
        let assets = editor.document.assets
        VStack(alignment: .leading, spacing: 0) {
            InspectorSection(title: "Colors", onAdd: { editor.addSwatch(nextColor(assets), name: "Color \(assets.swatches.count + 1)") }) {
                if assets.swatches.isEmpty {
                    Text("Add colors with + or with Add Color to Palette on a selected layer. Use them with C or as $name in the command line.")
                        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                ForEach(assets.swatches) { swatch in
                    SwatchRow(editor: editor, swatch: swatch)
                }
            }
            InspectorSection(title: "Shared Styles") {
                if assets.sharedStyles.isEmpty {
                    Text("Select a styled layer and use Create Shared Style… to reuse its look.")
                        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                ForEach(assets.sharedStyles) { style in
                    StyleRow(editor: editor, style: style)
                }
            }
        }
    }

    /// New swatches start from a gray that is not in the palette yet.
    private func nextColor(_ assets: DocumentAssets) -> SkicaCore.Color {
        let used = Set(assets.swatches.map(\.color))
        return stride(from: 0x80, through: 0xF0, by: 8).map { SkicaCore.Color(red: UInt8($0), green: UInt8($0), blue: UInt8($0)) }
            .first { !used.contains($0) } ?? .black
    }
}

private struct SwatchRow: View {
    let editor: DocumentEditor
    let swatch: Swatch

    @State private var name = ""
    @State private var isFocused = false

    var body: some View {
        HStack(spacing: 6) {
            ColorSwatch(color: swatch.color) { color in
                editor.updateSwatch(swatch.id, coalescingKey: "swatch-\(swatch.id)") { $0.color = color }
            }
            FieldBox(prefix: nil, isFocused: isFocused) {
                KeyTextField(text: $name, font: .systemFont(ofSize: 11), isBordered: false, onSubmit: commit, onEndEditing: commit,
                             onTab: commit, onFocusChange: { isFocused = $0 })
                Text(swatch.color.hex).font(.system(size: 10).monospaced()).foregroundStyle(.tertiary).fixedSize()
            }
            IconButton(symbol: "minus", help: "Remove from palette") { editor.deleteSwatch(swatch.id) }
        }
        .onAppear { name = swatch.name }
        .onChange(of: swatch.name) { name = swatch.name }
    }

    private func commit() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != swatch.name else { return name = swatch.name }
        editor.updateSwatch(swatch.id) { $0.name = trimmed }
    }
}

private struct StyleRow: View {
    let editor: DocumentEditor
    let style: SharedStyle

    @State private var name = ""
    @State private var isFocused = false

    var body: some View {
        let _ = editor.revision
        HStack(spacing: 6) {
            Image(systemName: style.isTextStyle ? "textformat" : "paintpalette")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            FieldBox(prefix: nil, isFocused: isFocused) {
                KeyTextField(text: $name, font: .systemFont(ofSize: 11), isBordered: false, onSubmit: commit, onEndEditing: commit,
                             onTab: commit, onFocusChange: { isFocused = $0 })
                Text("\(editor.document.layers(using: style.id).count)")
                    .font(.system(size: 10).monospacedDigit()).foregroundStyle(.tertiary).fixedSize()
                    .help("Layers using this style")
            }
            IconButton(symbol: "minus", help: "Delete style (layers keep their look)") { editor.deleteSharedStyle(style.id) }
        }
        .onAppear { name = style.name }
        .onChange(of: style.name) { name = style.name }
    }

    private func commit() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != style.name else { return name = style.name }
        editor.renameSharedStyle(style.id, to: trimmed)
    }
}
