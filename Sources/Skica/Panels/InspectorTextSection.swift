import AppKit
import SkicaCore
import SwiftUI

/// What the inspector asks the window to do for text, so changes can go to the characters
/// selected while typing rather than the whole layer.
struct TextActions {
    var applyStyle: (String, @escaping (TextStyle) -> TextStyle) -> Void
    var updateContent: (String, @escaping (inout TextContent) -> Void) -> Void
    var chooseFont: () -> Void
}

/// Font, size, color, spacing, alignment and sizing of the selected text layers.
struct TextSection: View {
    let layers: [Layer]
    let actions: TextActions

    var body: some View {
        let contents = layers.compactMap(\.textContent)
        let styles = contents.flatMap { $0.runs.map(\.style) }
        let first = styles.first ?? TextStyle()
        InspectorSection(title: "Text") {
            Button(action: actions.chooseFont) {
                FieldBox(prefix: .symbol("textformat"), isFocused: false) {
                    Text(shared(styles, \.familyName) ?? "Mixed")
                        .font(.system(size: 11))
                        .lineLimit(1)
                    Spacer(minLength: 2)
                    Text("⌘T").font(.system(size: 10)).foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Choose a font family (⌘T)")

            HStack(spacing: 6) {
                MenuField(prefix: nil, title: shared(styles, \.faceName) ?? "Mixed", options: faces(of: first.familyName)) { face in
                    let members = NSFontManager.shared.availableMembers(ofFontFamily: first.familyName) ?? []
                    guard let name = members.first(where: { ($0[safe: 1] as? String) == face })?.first as? String else { return }
                    actions.applyStyle("Change Font Style") { style in
                        var style = style
                        style.fontName = name
                        return style
                    }
                }
                NumberField(.symbol("textformat.size"), help: "Font size", value: shared(styles, \.fontSize), minimum: 1, maximum: 2000) { size in
                    actions.applyStyle("Change Font Size") { style in
                        var style = style
                        style.fontSize = size
                        return style
                    }
                }
                .frame(width: 78)
            }

            HStack(spacing: 6) {
                ColorSwatch(color: first.color) { color in setColor(color) }
                HexField(color: shared(styles, \.color) ?? first.color) { color in setColor(color) }
            }

            Grid(horizontalSpacing: 6, verticalSpacing: 6) {
                GridRow {
                    NumberField(.symbol("character"), help: "Letter spacing", value: shared(styles, \.letterSpacing)) { spacing in
                        actions.applyStyle("Change Letter Spacing") { style in
                            var style = style
                            style.letterSpacing = spacing
                            return style
                        }
                    }
                    LineHeightField(value: shared(styles) { $0.lineHeight ?? -1 }.flatMap { $0 < 0 ? nil : $0 }) { height in
                        actions.applyStyle("Change Line Height") { style in
                            var style = style
                            style.lineHeight = height
                            return style
                        }
                    }
                }
            }

            HStack(spacing: 2) {
                ForEach(TextContent.Alignment.allCases, id: \.self) { alignment in
                    let isOn = contents.allSatisfy { $0.alignment == alignment }
                    IconButton(symbol: alignment.symbolName, help: "Align \(alignment.rawValue)") {
                        actions.updateContent("Align Text") { $0.alignment = alignment }
                    }
                    .background(isOn ? AnyShapeStyle(.tint.opacity(0.15)) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 5))
                }
                Spacer(minLength: 6)
                IconButton(symbol: "underline", help: "Underline (⌘U)") {
                    let turnOn = styles.contains { !$0.underline }
                    actions.applyStyle("Underline") { style in
                        var style = style
                        style.underline = turnOn
                        return style
                    }
                }
                .background(styles.allSatisfy(\.underline) ? AnyShapeStyle(.tint.opacity(0.15)) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 5))
            }

            MenuField(prefix: .symbol("arrow.left.and.right.text.vertical"),
                      title: shared(contents, \.sizing)?.title ?? "Mixed",
                      options: TextContent.Sizing.allCases.map(\.title)) { title in
                guard let sizing = TextContent.Sizing.allCases.first(where: { $0.title == title }) else { return }
                actions.updateContent("Change Text Sizing") { $0.sizing = sizing }
            }
        }
    }

    private func setColor(_ color: SkicaCore.Color) {
        actions.applyStyle("Change Text Color") { style in
            var style = style
            style.color = color
            return style
        }
    }

    private func faces(of family: String) -> [String] {
        (NSFontManager.shared.availableMembers(ofFontFamily: family) ?? []).compactMap { $0[safe: 1] as? String }
    }

    private func shared<Value: Equatable, Item>(_ items: [Item], _ value: (Item) -> Value) -> Value? {
        guard let first = items.first.map(value) else { return nil }
        return items.allSatisfy { value($0) == first } ? first : nil
    }

    private func shared<Value: Equatable, Item>(_ items: [Item], _ keyPath: KeyPath<Item, Value>) -> Value? {
        shared(items) { $0[keyPath: keyPath] }
    }
}

/// Line height in points; empty means the font's own ("Auto").
private struct LineHeightField: View {
    let value: Double?
    let commit: (Double?) -> Void

    @State private var text = ""
    @State private var isFocused = false

    var body: some View {
        FieldBox(prefix: .symbol("arrow.up.and.down.text.horizontal"), isFocused: isFocused) {
            KeyTextField(
                text: $text,
                placeholder: "Auto",
                font: .monospacedDigitSystemFont(ofSize: 11, weight: .regular),
                isBordered: false,
                onSubmit: submit,
                onStep: { direction, large in
                    let current = value ?? 20
                    commit(max(current + Double(direction) * (large ? 10 : 1), 1))
                    return true
                },
                onEndEditing: { text = Self.display(value) },
                onTab: submit,
                onFocusChange: { isFocused = $0 }
            )
        }
        .help("Line height (empty for automatic)")
        .onAppear { text = Self.display(value) }
        .onChange(of: value) { text = Self.display(value) }
    }

    private static func display(_ value: Double?) -> String {
        value.map(NumberField.display) ?? ""
    }

    private func submit() {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed.lowercased() == "auto" {
            if value != nil { commit(nil) }
            return
        }
        guard let height = try? NumericExpression.evaluate(trimmed, current: value), height > 0 else {
            NSSound.beep()
            text = Self.display(value)
            return
        }
        commit(height)
    }
}

extension TextContent.Alignment {
    var symbolName: String {
        switch self {
        case .left: "text.alignleft"
        case .center: "text.aligncenter"
        case .right: "text.alignright"
        case .justified: "text.justify"
        }
    }
}
