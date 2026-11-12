import SkicaCore
import SwiftUI

/// The vim-like line at the bottom: tool, selection, pending keys, pointer and zoom.
/// It turns into a one-line prompt: size and position (`=`, ↩), page names, the command line (`:`).
struct StatusBar: View {
    let state: EditorState
    let editor: DocumentEditor
    let onPromptSubmit: (String) -> Void

    var body: some View {
        HStack(spacing: 14) {
            if let prompt = state.prompt {
                promptField(prompt)
            } else {
                Text(state.mode ?? editor.tool.title)
                    .fontWeight(.semibold)
                    .foregroundStyle(state.mode == nil ? AnyShapeStyle(.primary) : AnyShapeStyle(.tint))
                Text(state.modeHint ?? selectionSummary)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if !state.pendingKeys.isEmpty {
                    Text(state.pendingKeys.map { $0.symbols.joined() }.joined(separator: " ") + "…")
                        .font(.system(size: 11, design: .monospaced))
                }
            }
            Spacer()
            if let message = state.message {
                Text(message)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .transition(.opacity)
            }
            if let cursor = state.cursor {
                Text("x \(Int(cursor.x.rounded()))   y \(Int(cursor.y.rounded()))")
                    .foregroundStyle(.secondary)
            }
            Text(zoomText)
                .frame(minWidth: 44, alignment: .trailing)
        }
        .font(.system(size: 11))
        .monospacedDigit()
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private func promptField(_ prompt: PromptState) -> some View {
        HStack(spacing: 8) {
            Text(prompt.title)
                .fontWeight(.semibold)
                .foregroundStyle(.tint)
            KeyTextField(
                text: Binding(get: { state.prompt?.text ?? "" }, set: { state.prompt?.text = $0 }),
                placeholder: prompt.placeholder,
                font: .monospacedSystemFont(ofSize: 11, weight: .regular),
                isBordered: false,
                focusOnAppear: true,
                onSubmit: { onPromptSubmit(state.prompt?.text ?? "") }
            )
            .frame(width: 320)
            if let error = prompt.error {
                Text(error).foregroundStyle(.red).lineLimit(1)
            } else if prompt.kind == .commandLine {
                Text(commandHelp(for: prompt.text)).foregroundStyle(.secondary).lineLimit(1)
            } else {
                Text(prompt.hint).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    /// Usage of the commands that start with the word being typed (the last after `;`).
    private func commandHelp(for text: String) -> String {
        let current = text.split(separator: ";", omittingEmptySubsequences: false).last ?? ""
        let word = current.trimmingCharacters(in: .whitespaces).split(separator: " ").first.map(String.init)?.lowercased() ?? ""
        let matches = LineCommand.reference.filter { word.isEmpty || $0.verb.hasPrefix(word) || word.hasPrefix($0.verb) }
        guard !matches.isEmpty else { return "Unknown command — w h x y size r rot op fill border shadow blur blend font fs color align…" }
        return matches.prefix(6).map(\.usage).joined(separator: "   ·   ")
    }

    private var selectionSummary: String {
        let _ = editor.revision
        let layers = editor.selectedLayers
        switch layers.count {
        case 0:
            return ""
        case 1:
            let frame = layers[0].frame
            return "\(layers[0].name)   \(format(frame.width)) × \(format(frame.height))   @ \(format(frame.x)), \(format(frame.y))"
        default:
            return "\(layers.count) layers"
        }
    }

    private func format(_ value: Double) -> String {
        NumberField.display(value)
    }

    private var zoomText: String {
        let percent = state.zoom * 100
        return percent < 10 ? String(format: "%.1f%%", percent) : "\(Int(percent.rounded()))%"
    }
}
