import AppKit
import SkicaCore
import SwiftUI

/// Fills, borders and shadows share the list UI: a colored row each, with show/hide and remove.
protocol PaintItem: Equatable {
    var isEnabled: Bool { get set }
    var color: SkicaCore.Color { get set }
}

extension Fill: PaintItem {}
extension Border: PaintItem {}
extension Shadow: PaintItem {}

/// A list section of the style (fills, borders, shadows, inner shadows). Edits apply to every
/// selected layer that has an item at that index; the list shown is the first layer's.
struct PaintListSection<Item: PaintItem, Extra: View>: View {
    let title: String
    let editor: DocumentEditor
    let layers: [Layer]
    let items: WritableKeyPath<Style, [Item]>
    let makeItem: () -> Item
    /// An optional button in each row (the fill type menu).
    var accessory: (Int, Item) -> AnyView? = { _, _ in nil }
    @ViewBuilder let extra: (Int, Item) -> Extra

    var body: some View {
        let list = layers.first?.style[keyPath: items] ?? []
        InspectorSection(title: title, onAdd: { editor.updateSelection("Add \(title)") { $0.style[keyPath: items].append(makeItem()) } }) {
            ForEach(Array(list.enumerated()), id: \.offset) { index, item in
                PaintRow(
                    color: item.color,
                    isEnabled: item.isEnabled,
                    swatch: swatch(for: item),
                    caption: (item as? Fill)?.gradient.map { $0.kind == .linear ? "Linear" : "Radial" },
                    accessory: accessory(index, item),
                    onColor: { color, live in update(index, "Change \(title)", key: live ? "\(title)-\(index)" : nil) { $0.color = color } },
                    onToggle: { update(index, item.isEnabled ? "Hide \(title)" : "Show \(title)") { $0.isEnabled.toggle() } },
                    onRemove: {
                        editor.updateSelection("Remove \(title)") { layer in
                            if layer.style[keyPath: items].indices.contains(index) { layer.style[keyPath: items].remove(at: index) }
                        }
                    }
                ) {
                    extra(index, item)
                }
            }
        }
    }

    /// Changes the item at `index` on every selected layer that has one.
    func update(_ index: Int, _ actionName: String, key: String? = nil, _ body: (inout Item) -> Void) {
        editor.updateSelection(actionName, coalescingKey: key) { layer in
            guard layer.style[keyPath: items].indices.contains(index) else { return }
            body(&layer.style[keyPath: items][index])
        }
    }

    private func swatch(for item: Item) -> AnyShapeStyle? {
        guard let fill = item as? Fill, let gradient = fill.gradient else { return nil }
        let stops = gradient.stops.sorted { $0.position < $1.position }.map {
            SwiftUI.Gradient.Stop(color: SwiftUI.Color(cgColor: $0.color.cgColor), location: $0.position)
        }
        return gradient.kind == .linear
            ? AnyShapeStyle(LinearGradient(stops: stops, startPoint: gradient.from.swiftUI, endPoint: gradient.to.swiftUI))
            : AnyShapeStyle(RadialGradient(stops: stops, center: gradient.from.swiftUI, startRadius: 0, endRadius: 13))
    }
}

/// Fill rows add a type button (solid, linear, radial) and, for gradients, the angle and color stops.
struct FillsSection: View {
    let editor: DocumentEditor
    let layers: [Layer]

    var body: some View {
        PaintListSection(
            title: "Fill", editor: editor, layers: layers, items: \.fills, makeItem: { Fill(Tool.defaultFill) },
            accessory: { index, fill in AnyView(FillTypeButton(fill: fill) { body in update(index, "Change Fill Type", nil, body) }) }
        ) { index, fill in
            if let gradient = fill.gradient {
                GradientEditor(gradient: gradient) { actionName, key, body in
                    update(index, actionName, key) { fill in
                        if var gradient = fill.gradient {
                            body(&gradient)
                            fill.gradient = gradient
                        }
                    }
                }
            }
        }
    }

    private func update(_ index: Int, _ actionName: String, _ key: String?, _ body: (inout Fill) -> Void) {
        editor.updateSelection(actionName, coalescingKey: key) { layer in
            if layer.style.fills.indices.contains(index) { body(&layer.style.fills[index]) }
        }
    }
}

/// Switches a fill between a solid color and linear or radial gradients.
private struct FillTypeButton: View {
    let fill: Fill
    let update: ((inout Fill) -> Void) -> Void

    private static let options = ["Solid", "Linear Gradient", "Radial Gradient"]

    private var current: String {
        switch fill.gradient?.kind {
        case nil: "Solid"
        case .linear: "Linear Gradient"
        case .radial: "Radial Gradient"
        }
    }

    var body: some View {
        IconButton(symbol: fill.gradient == nil ? "square.fill" : "square.bottomhalf.filled", help: "Fill type: \(current)") {
            OptionsMenu.show(Self.options, selected: current) { choice in
                update { fill in
                    switch choice {
                    case "Linear Gradient": fill.switchToGradient(.linear)
                    case "Radial Gradient": fill.switchToGradient(.radial)
                    default:
                        if let first = fill.gradient?.stops.first { fill.color = first.color }
                        fill.gradient = nil
                    }
                }
            }
        }
    }
}

private extension Fill {
    /// Keeps existing stops when changing between gradient kinds; starts from the solid color otherwise.
    mutating func switchToGradient(_ kind: SkicaCore.Gradient.Kind) {
        let fresh = SkicaCore.Gradient.fading(color, kind: kind)
        guard var current = gradient else {
            gradient = fresh
            return
        }
        current.kind = kind
        current.from = fresh.from
        current.to = fresh.to
        gradient = current
    }
}

/// The angle (linear gradients) and the color stops of a gradient fill.
private struct GradientEditor: View {
    let gradient: SkicaCore.Gradient
    let update: (String, String?, (inout SkicaCore.Gradient) -> Void) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if gradient.kind == .linear {
                NumberField(.symbol("arrow.up.right"), help: "Angle", value: gradient.angle.rounded(), suffix: "°") { angle in
                    update("Change Gradient Angle", "gradient-angle") { $0.angle = angle }
                }
                .frame(width: 100)
            }
            ForEach(Array(gradient.stops.enumerated()), id: \.offset) { index, stop in
                HStack(spacing: 6) {
                    ColorSwatch(color: stop.color) { color in
                        update("Change Gradient", "stop-\(index)") { $0.stops[safe: index]?.color = color }
                    }
                    HexField(color: stop.color) { color in
                        update("Change Gradient", nil) { $0.stops[safe: index]?.color = color }
                    }
                    NumberField(nil, help: "Stop position", value: (stop.position * 100).rounded(), minimum: 0, maximum: 100, suffix: "%") { position in
                        update("Move Gradient Stop", "stop-position-\(index)") { $0.stops[safe: index]?.position = position / 100 }
                    }
                    .frame(width: 58)
                    IconButton(symbol: "minus", help: "Remove stop") {
                        update("Remove Gradient Stop", nil) { gradient in
                            if gradient.stops.count > 2, gradient.stops.indices.contains(index) { gradient.stops.remove(at: index) }
                        }
                    }
                    .disabled(gradient.stops.count <= 2)
                }
            }
            Button {
                update("Add Gradient Stop", nil) { gradient in
                    let stops = gradient.stops.sorted { $0.position < $1.position }
                    guard let last = stops.last else { return }
                    let previous = stops.dropLast().last ?? last
                    gradient.stops.append(GradientStop(position: (previous.position + last.position) / 2, color: last.color))
                }
            } label: {
                Label("Add stop", systemImage: "plus").font(.system(size: 11))
            }
            .buttonStyle(.borderless)
        }
    }
}

struct BordersSection: View {
    let editor: DocumentEditor
    let layers: [Layer]

    var body: some View {
        let isLine = layers.allSatisfy { ShapePath.isOpen($0.kind) }
        PaintListSection(title: "Border", editor: editor, layers: layers, items: \.borders, makeItem: { Border(Tool.defaultBorder) }) { index, border in
            let update = { (actionName: String, key: String?, body: (inout Border) -> Void) in
                editor.updateSelection(actionName, coalescingKey: key) { layer in
                    if layer.style.borders.indices.contains(index) { body(&layer.style.borders[index]) }
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    NumberField(.symbol("lineweight"), help: "Border width", value: border.width, minimum: 0) { width in
                        update("Change Border Width", "border-width-\(index)") { $0.width = width }
                    }
                    if !isLine {
                        MenuField(prefix: nil, title: border.position.rawValue.capitalized, options: Border.Position.allCases.map { $0.rawValue.capitalized }) { choice in
                            update("Change Border Position", nil) { $0.position = Border.Position(rawValue: choice.lowercased()) ?? .center }
                        }
                    }
                }
                HStack(spacing: 6) {
                    DashField(dashes: border.dashes) { dashes in update("Change Dashes", nil) { $0.dashes = dashes } }
                    IconMenuButton(symbol: "line.diagonal", help: "Line ends", selected: border.cap.rawValue.capitalized,
                                   options: Border.Cap.allCases.map { $0.rawValue.capitalized }) { choice in
                        update("Change Line Ends", nil) { $0.cap = Border.Cap(rawValue: choice.lowercased()) ?? .butt }
                    }
                    IconMenuButton(symbol: "skew", help: "Corners", selected: border.join.rawValue.capitalized,
                                   options: Border.Join.allCases.map { $0.rawValue.capitalized }) { choice in
                        update("Change Corners", nil) { $0.join = Border.Join(rawValue: choice.lowercased()) ?? .miter }
                    }
                }
            }
        }
    }
}

struct ShadowsSection: View {
    let title: String
    let editor: DocumentEditor
    let layers: [Layer]
    let items: WritableKeyPath<Style, [Shadow]>

    var body: some View {
        PaintListSection(title: title, editor: editor, layers: layers, items: items, makeItem: { Shadow() }) { index, shadow in
            let update = { (actionName: String, key: String, body: (inout Shadow) -> Void) in
                editor.updateSelection(actionName, coalescingKey: "\(title)-\(key)-\(index)") { layer in
                    if layer.style[keyPath: items].indices.contains(index) { body(&layer.style[keyPath: items][index]) }
                }
            }
            Grid(horizontalSpacing: 6, verticalSpacing: 6) {
                GridRow {
                    NumberField(.text("X"), help: "Horizontal offset", value: shadow.x) { value in update("Change \(title)", "x") { $0.x = value } }
                    NumberField(.text("Y"), help: "Vertical offset", value: shadow.y) { value in update("Change \(title)", "y") { $0.y = value } }
                }
                GridRow {
                    NumberField(.symbol("drop"), help: "Blur", value: shadow.blur, minimum: 0) { value in update("Change \(title)", "blur") { $0.blur = value } }
                    NumberField(.symbol("arrow.up.left.and.arrow.down.right"), help: "Spread", value: shadow.spread) { value in update("Change \(title)", "spread") { $0.spread = value } }
                }
            }
        }
    }
}

/// Layer blur and blend mode.
struct EffectsSection: View {
    let editor: DocumentEditor
    let layers: [Layer]

    var body: some View {
        let blur = layers.first?.style.blur
        let blendModes = Set(layers.map(\.style.blendMode))
        InspectorSection(title: "Effects", onAdd: blur == nil ? { editor.updateSelection("Add Blur") { $0.style.blur = Blur() } } : nil) {
            MenuField(prefix: .symbol("square.on.square.intersection.dashed"),
                      title: blendModes.count == 1 ? blendModes.first!.title : "Mixed",
                      options: BlendMode.allCases.map(\.title)) { choice in
                let mode = BlendMode.allCases.first { $0.title == choice } ?? .normal
                editor.updateSelection("Change Blend Mode") { $0.style.blendMode = mode }
            }
            if let blur {
                HStack(spacing: 6) {
                    NumberField(.symbol("drop.halffull"), help: "Blur radius", value: blur.radius, minimum: 0) { radius in
                        editor.updateSelection("Change Blur", coalescingKey: "blur") { $0.style.blur?.radius = radius }
                    }
                    .opacity(blur.isEnabled ? 1 : 0.45)
                    IconButton(symbol: blur.isEnabled ? "eye" : "eye.slash", help: blur.isEnabled ? "Hide blur" : "Show blur") {
                        editor.updateSelection(blur.isEnabled ? "Hide Blur" : "Show Blur") { $0.style.blur?.isEnabled.toggle() }
                    }
                    IconButton(symbol: "minus", help: "Remove blur") {
                        editor.updateSelection("Remove Blur") { $0.style.blur = nil }
                    }
                }
            }
        }
    }
}

/// A choice from a short list, styled like the other inspector fields.
struct MenuField: View {
    let prefix: FieldPrefix?
    let title: String
    let options: [String]
    let choose: (String) -> Void

    /// SwiftUI's `Menu` flattens custom labels on macOS, so this is a button that pops up an NSMenu.
    var body: some View {
        Button {
            OptionsMenu.show(options, selected: title, choose: choose)
        } label: {
            FieldBox(prefix: prefix, isFocused: false) {
                Text(title)
                    .font(.system(size: 11))
                    .lineLimit(1)
                Spacer(minLength: 2)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A small icon button that opens a menu of choices; the help text names the current one.
struct IconMenuButton: View {
    let symbol: String
    let help: String
    let selected: String
    let options: [String]
    let choose: (String) -> Void

    var body: some View {
        IconButton(symbol: symbol, help: "\(help): \(selected)") {
            OptionsMenu.show(options, selected: selected, choose: choose)
        }
    }
}

/// A pop-up menu of strings at the pointer, with the current choice checked.
final class OptionsMenu: NSObject {
    private let choose: (String) -> Void

    private init(choose: @escaping (String) -> Void) {
        self.choose = choose
    }

    static func show(_ options: [String], selected: String, choose: @escaping (String) -> Void) {
        let handler = OptionsMenu(choose: choose)
        let menu = NSMenu()
        for option in options {
            let item = NSMenuItem(title: option, action: #selector(picked(_:)), keyEquivalent: "")
            item.target = handler
            item.state = option == selected ? .on : .off
            menu.addItem(item)
        }
        // The menu runs modally here, which keeps the handler alive until a choice is made.
        withExtendedLifetime(handler) {
            _ = menu.popUp(positioning: menu.items.first { $0.state == .on }, at: NSEvent.mouseLocation, in: nil)
        }
    }

    @objc private func picked(_ item: NSMenuItem) {
        choose(item.title)
    }
}

/// Dash and gap lengths typed as numbers, e.g. `4 2`; empty for a solid line.
private struct DashField: View {
    let dashes: [Double]
    let commit: ([Double]) -> Void

    @State private var text = ""
    @State private var isFocused = false

    var body: some View {
        FieldBox(prefix: .symbol("line.horizontal.3"), isFocused: isFocused) {
            KeyTextField(
                text: $text,
                placeholder: "Solid",
                font: .monospacedDigitSystemFont(ofSize: 11, weight: .regular),
                isBordered: false,
                onSubmit: submit,
                onEndEditing: { text = Self.display(dashes) },
                onTab: submit,
                onFocusChange: { isFocused = $0 }
            )
        }
        .help("Dashes: dash and gap lengths, e.g. 4 2")
        .onAppear { text = Self.display(dashes) }
        .onChange(of: dashes) { text = Self.display(dashes) }
    }

    private static func display(_ dashes: [Double]) -> String {
        dashes.map(NumberField.display).joined(separator: " ")
    }

    private func submit() {
        let parts = text.split(whereSeparator: { $0 == " " || $0 == "," })
        let values = parts.compactMap { Double($0) }
        guard values.count == parts.count, values.allSatisfy({ $0 >= 0 }) else {
            NSSound.beep()
            text = Self.display(dashes)
            return
        }
        commit(values)
    }
}

extension SkicaCore.UnitPoint {
    var swiftUI: SwiftUI.UnitPoint { SwiftUI.UnitPoint(x: x, y: y) }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        get { indices.contains(index) ? self[index] : nil }
        set {
            guard let newValue, indices.contains(index) else { return }
            self[index] = newValue
        }
    }
}
