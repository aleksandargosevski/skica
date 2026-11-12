import SkicaCore
import SwiftUI

/// The selected layers' export presets (size, suffix, format) and the export button.
/// Edits apply to every selected layer; the list shown is the first layer's.
struct ExportSection: View {
    let editor: DocumentEditor
    let layers: [Layer]
    let export: () -> Void

    var body: some View {
        let presets = layers.first?.exports ?? []
        InspectorSection(title: "Export", onAdd: {
            editor.updateSelection("Add Export Size") { $0.exports.append(ExportPreset.next(after: $0.exports)) }
        }) {
            ForEach(Array(presets.enumerated()), id: \.offset) { index, preset in
                HStack(spacing: 6) {
                    SizeField(size: preset.size) { size in
                        update(index, "Change Export Size") { preset in
                            // Keep a suffix that was derived from the size in step with it.
                            if preset.suffix == ExportPreset.defaultSuffix(for: preset.size) {
                                preset.suffix = ExportPreset.defaultSuffix(for: size)
                            }
                            preset.size = size
                        }
                    }
                    .frame(width: 52)
                    SuffixField(suffix: preset.suffix) { suffix in
                        update(index, "Change Export Suffix") { $0.suffix = suffix }
                    }
                    .frame(minWidth: 64)
                    MenuField(prefix: nil, title: preset.format.title, options: ExportPreset.Format.allCases.map(\.title)) { title in
                        guard let format = ExportPreset.Format.allCases.first(where: { $0.title == title }) else { return }
                        update(index, "Change Export Format") { $0.format = format }
                    }
                    .frame(width: 70)
                    IconButton(symbol: "minus", help: "Remove") {
                        editor.updateSelection("Remove Export Size") { layer in
                            if layer.exports.indices.contains(index) { layer.exports.remove(at: index) }
                        }
                    }
                }
            }
            Button(action: export) {
                HStack {
                    Image(systemName: "square.and.arrow.up")
                    Text(exportTitle(presets))
                    Spacer()
                    Text("⇧⌘E").foregroundStyle(.secondary)
                }
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 10)
                .frame(height: 28)
                .frame(maxWidth: .infinity)
                .background(SwiftUI.Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private func exportTitle(_ presets: [ExportPreset]) -> String {
        let name = layers.count == 1 ? layers[0].name : "\(layers.count) Layers"
        return presets.isEmpty ? "Export \(name) (1x PNG)…" : "Export \(name)…"
    }

    private func update(_ index: Int, _ actionName: String, _ body: (inout ExportPreset) -> Void) {
        editor.updateSelection(actionName) { layer in
            if layer.exports.indices.contains(index) { body(&layer.exports[index]) }
        }
    }
}

/// `1x`, `2x`, `512w`, `300h`.
private struct SizeField: View {
    let size: ExportPreset.Size
    let commit: (ExportPreset.Size) -> Void

    @State private var text = ""
    @State private var isFocused = false

    var body: some View {
        FieldBox(prefix: nil, isFocused: isFocused) {
            KeyTextField(text: $text, font: .monospacedDigitSystemFont(ofSize: 11, weight: .regular), isBordered: false,
                         onSubmit: submit, onEndEditing: { text = size.description }, onTab: submit,
                         onFocusChange: { isFocused = $0 })
        }
        .help("Size: 2x, 0.5x, 512w (width) or 300h (height)")
        .onAppear { text = size.description }
        .onChange(of: size) { text = size.description }
    }

    private func submit() {
        guard let parsed = ExportPreset.Size(parsing: text) else {
            NSSound.beep()
            text = size.description
            return
        }
        if parsed != size { commit(parsed) }
    }
}

private struct SuffixField: View {
    let suffix: String
    let commit: (String) -> Void

    @State private var text = ""
    @State private var isFocused = false

    var body: some View {
        FieldBox(prefix: nil, isFocused: isFocused) {
            KeyTextField(text: $text, placeholder: "Suffix", font: .systemFont(ofSize: 11), isBordered: false,
                         onSubmit: submit, onEndEditing: submit, onTab: submit, onFocusChange: { isFocused = $0 })
        }
        .help("Added to the file name, e.g. @2x")
        .onAppear { text = suffix }
        .onChange(of: suffix) { text = suffix }
    }

    private func submit() {
        if text != suffix { commit(text) }
    }
}
