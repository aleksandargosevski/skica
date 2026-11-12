import AppKit
import SkicaCore
import SwiftUI

/// What a field shows inside on the left: a short label (`X`) or an SF Symbol.
enum FieldPrefix {
    case text(String)
    case symbol(String)
}

/// The rounded, softly filled box every inspector input sits in; the border turns accent on focus.
struct FieldBox<Content: View>: View {
    var prefix: FieldPrefix?
    var isFocused: Bool
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 5) {
            switch prefix {
            case .text(let text):
                Text(text)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 9, alignment: .leading)
            case .symbol(let name):
                Image(systemName: name)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .frame(width: 12)
            case nil:
                EmptyView()
            }
            content
        }
        .padding(.horizontal, 7)
        .frame(height: 26)
        .background(SwiftUI.Color.primary.opacity(isFocused ? 0.03 : 0.055), in: RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(isFocused ? AnyShapeStyle(.tint) : AnyShapeStyle(SwiftUI.Color.primary.opacity(0.06)), lineWidth: isFocused ? 1.5 : 1)
        )
        .animation(.easeOut(duration: 0.12), value: isFocused)
    }
}

/// A number input: arithmetic (`100/3`, `+20`, `*2`), ↑/↓ steps by 1 (10 with shift),
/// ↩ or ⇥ apply, esc or clicking away discard. nil shows "Mixed".
struct NumberField: View {
    let prefix: FieldPrefix?
    let help: String
    let value: Double?
    var minimum: Double?
    var maximum: Double?
    var suffix: String?
    /// Shown when there is no single value.
    var placeholder = "Mixed"
    let commit: (Double) -> Void

    @State private var text = ""
    @State private var isFocused = false

    init(_ prefix: FieldPrefix?, help: String, value: Double?, minimum: Double? = nil, maximum: Double? = nil,
         suffix: String? = nil, placeholder: String = "Mixed", commit: @escaping (Double) -> Void) {
        self.placeholder = placeholder
        self.prefix = prefix
        self.help = help
        self.value = value
        self.minimum = minimum
        self.maximum = maximum
        self.suffix = suffix
        self.commit = commit
    }

    var body: some View {
        FieldBox(prefix: prefix, isFocused: isFocused) {
            KeyTextField(
                text: $text,
                placeholder: value == nil ? placeholder : "",
                font: .monospacedDigitSystemFont(ofSize: 11, weight: .regular),
                isBordered: false,
                onSubmit: submit,
                onStep: step,
                onEndEditing: { text = Self.display(value) },
                onTab: submit,
                onFocusChange: { isFocused = $0 }
            )
            if let suffix {
                Text(suffix)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
        .help(help)
        .onAppear { text = Self.display(value) }
        .onChange(of: value) { text = Self.display(value) }
    }

    private func submit() {
        guard text != Self.display(value) else { return }
        do {
            apply(try NumericExpression.evaluate(text, current: value))
        } catch {
            NSSound.beep()
            text = Self.display(value)
        }
    }

    private func step(_ direction: Int, _ large: Bool) -> Bool {
        let current = (try? NumericExpression.evaluate(text, current: value)) ?? value ?? 0
        apply(current + Double(direction) * (large ? 10 : 1))
        return true
    }

    private func apply(_ newValue: Double) {
        var clamped = newValue
        if let minimum { clamped = max(clamped, minimum) }
        if let maximum { clamped = min(clamped, maximum) }
        commit(clamped)
        text = Self.display(clamped)
    }

    static func display(_ value: Double?) -> String {
        guard let value else { return "" }
        let rounded = (value * 100).rounded() / 100
        return rounded == rounded.rounded() ? String(Int(rounded)) : String(rounded)
    }
}

/// A hex color input (`#FF6600`, `f60`, `#FF660080`).
struct HexField: View {
    let color: SkicaCore.Color
    let commit: (SkicaCore.Color) -> Void

    @State private var text = ""
    @State private var isFocused = false

    var body: some View {
        FieldBox(prefix: nil, isFocused: isFocused) {
            KeyTextField(
                text: $text,
                font: .monospacedSystemFont(ofSize: 11, weight: .regular),
                isBordered: false,
                onSubmit: submit,
                onEndEditing: { text = Self.display(color) },
                onTab: submit,
                onFocusChange: { isFocused = $0 }
            )
            .frame(minWidth: 50)
            Text("\(Int((Double(color.alpha) / 255 * 100).rounded()))%")
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(.tertiary)
                .fixedSize()
        }
        .onAppear { text = Self.display(color) }
        .onChange(of: color) { text = Self.display(color) }
    }

    /// Without `#` and alpha, which is shown separately.
    private static func display(_ color: SkicaCore.Color) -> String {
        String(color.hex.dropFirst().prefix(6))
    }

    private func submit() {
        guard text != Self.display(color) else { return }
        guard var parsed = SkicaCore.Color(hex: text) else {
            NSSound.beep()
            text = Self.display(color)
            return
        }
        // Six digits keep the current opacity; eight set it.
        if text.filter(\.isHexDigit).count <= 6 { parsed.alpha = color.alpha }
        commit(parsed)
    }
}

/// A rounded color chip with a checkerboard behind transparent colors; opens the color panel.
struct ColorSwatch: View {
    let color: SkicaCore.Color
    /// Shown instead of the plain color, e.g. a gradient preview.
    var style: AnyShapeStyle?
    /// Called continuously while the color panel is used.
    let onChange: (SkicaCore.Color) -> Void

    var body: some View {
        Button {
            ColorPanelBridge.shared.open(color, onChange: onChange)
        } label: {
            ZStack {
                Checkerboard()
                RoundedRectangle(cornerRadius: 5).fill(style ?? AnyShapeStyle(SwiftUI.Color(cgColor: color.cgColor)))
            }
            .frame(width: 26, height: 26)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(SwiftUI.Color.primary.opacity(0.15)))
        }
        .buttonStyle(.plain)
        .help("Choose color")
    }
}

private struct Checkerboard: View {
    var body: some View {
        Canvas { context, size in
            let cell: CGFloat = 4
            for row in 0..<Int(ceil(size.height / cell)) {
                for column in 0..<Int(ceil(size.width / cell)) where (row + column).isMultiple(of: 2) {
                    context.fill(Path(CGRect(x: CGFloat(column) * cell, y: CGFloat(row) * cell, width: cell, height: cell)), with: .color(.gray.opacity(0.3)))
                }
            }
        }
        .background(.white)
    }
}

/// Small square icon buttons (+, −, eye) with a hover background.
struct IconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isHovered ? .primary : .secondary)
                .frame(width: 22, height: 22)
                .background(SwiftUI.Color.primary.opacity(isHovered ? 0.08 : 0), in: RoundedRectangle(cornerRadius: 5))
                .contentShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(help)
    }
}

/// Sends changes from the shared color panel to whichever swatch opened it last.
final class ColorPanelBridge: NSObject {
    static let shared = ColorPanelBridge()
    private var onChange: ((SkicaCore.Color) -> Void)?

    func open(_ color: SkicaCore.Color, onChange: @escaping (SkicaCore.Color) -> Void) {
        let panel = NSColorPanel.shared
        self.onChange = nil
        panel.showsAlpha = true
        panel.isContinuous = true
        panel.color = NSColor(cgColor: color.cgColor) ?? .white
        panel.setTarget(self)
        panel.setAction(#selector(colorChanged(_:)))
        self.onChange = onChange
        panel.orderFront(nil)
    }

    @objc private func colorChanged(_ panel: NSColorPanel) {
        guard let color = SkicaCore.Color(cgColor: panel.color.cgColor) else { return }
        onChange?(color)
    }
}

extension SkicaCore.Color {
    init?(cgColor: CGColor) {
        guard let color = NSColor(cgColor: cgColor)?.usingColorSpace(.sRGB) else { return nil }
        func byte(_ value: CGFloat) -> UInt8 { UInt8((min(max(value, 0), 1) * 255).rounded()) }
        self.init(red: byte(color.redComponent), green: byte(color.greenComponent), blue: byte(color.blueComponent), alpha: byte(color.alphaComponent))
    }
}
