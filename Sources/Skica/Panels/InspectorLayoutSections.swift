import SkicaCore
import SwiftUI

/// Stack layout of the selected containers: direction, gap, padding, alignment and sizing.
struct StackSection: View {
    let editor: DocumentEditor
    let layers: [Layer]

    var body: some View {
        let stacks = layers.compactMap(\.stack)
        if stacks.count == layers.count, let first = stacks.first {
            InspectorSection(title: "Stack") {
                HStack(spacing: 6) {
                    MenuField(prefix: .symbol(first.direction == .horizontal ? "arrow.right" : "arrow.down"),
                              title: common(stacks, \.direction).map(Self.title) ?? "Mixed",
                              options: StackLayout.Direction.allCases.map(Self.title)) { choice in
                        guard let direction = StackLayout.Direction.allCases.first(where: { Self.title($0) == choice }) else { return }
                        editor.updateStack("Change Direction") { $0.direction = direction }
                    }
                    NumberField(.symbol(first.direction == .horizontal ? "arrow.left.and.right" : "arrow.up.and.down"), help: "Gap",
                                value: common(stacks, \.spacing), minimum: 0) { gap in
                        editor.updateStack("Change Gap") { $0.spacing = gap }
                    }
                    .frame(width: 76)
                    IconButton(symbol: "minus", help: "Remove stack (⌥⇧A)") { editor.removeStack() }
                }
                HStack(spacing: 6) {
                    paddingField("T", "Top padding", \.top, stacks)
                    paddingField("R", "Right padding", \.right, stacks)
                    paddingField("B", "Bottom padding", \.bottom, stacks)
                    paddingField("L", "Left padding", \.left, stacks)
                }
                HStack(spacing: 6) {
                    MenuField(prefix: .symbol("align.vertical.center"), title: common(stacks, \.alignment).map(Self.title) ?? "Mixed",
                              options: StackLayout.Alignment.allCases.map(Self.title)) { choice in
                        guard let alignment = StackLayout.Alignment.allCases.first(where: { Self.title($0) == choice }) else { return }
                        editor.updateStack("Change Alignment") { $0.alignment = alignment }
                    }
                    MenuField(prefix: .symbol("arrow.up.left.and.arrow.down.right"),
                              title: common(stacks, \.hugsContents).map { $0 ? Self.hug : Self.fixed } ?? "Mixed",
                              options: [Self.hug, Self.fixed]) { choice in
                        editor.updateStack("Change Sizing") { $0.hugsContents = choice == Self.hug }
                    }
                }
            }
        } else if layers.allSatisfy(\.isContainer) {
            InspectorSection(title: "Stack", onAdd: { editor.addStack() }) { EmptyView() }
        }
    }

    private static let hug = "Hug"
    private static let fixed = "Fixed"

    private static func title(_ direction: StackLayout.Direction) -> String {
        direction == .horizontal ? "Row" : "Column"
    }

    private static func title(_ alignment: StackLayout.Alignment) -> String {
        switch alignment {
        case .start: "Start"
        case .center: "Center"
        case .end: "End"
        }
    }

    private func paddingField(_ label: String, _ help: String, _ edge: WritableKeyPath<Insets, Double>, _ stacks: [StackLayout]) -> some View {
        NumberField(.text(label), help: help, value: common(stacks.map { $0.padding[keyPath: edge] }, \.self), minimum: 0) { value in
            editor.updateStack("Change Padding", coalescingKey: nil) { $0.padding[keyPath: edge] = value }
        }
    }

    private func common<Item, Value: Equatable>(_ items: [Item], _ key: KeyPath<Item, Value>) -> Value? {
        guard let first = items.first?[keyPath: key], items.allSatisfy({ $0[keyPath: key] == first }) else { return nil }
        return first
    }
}

/// How the selected layers follow their artboard or symbol when it is resized.
struct ConstraintsSection: View {
    let editor: DocumentEditor
    let layers: [Layer]

    var body: some View {
        InspectorSection(title: "Resizing") {
            HStack(spacing: 6) {
                MenuField(prefix: .symbol("arrow.left.and.right"), title: title(\.horizontal, horizontal: true),
                          options: Constraints.Pin.allCases.map { Self.name($0, horizontal: true) }) { choice in
                    guard let pin = Constraints.Pin.allCases.first(where: { Self.name($0, horizontal: true) == choice }) else { return }
                    editor.updateSelection("Change Constraints") { $0.constraints.horizontal = pin }
                }
                MenuField(prefix: .symbol("arrow.up.and.down"), title: title(\.vertical, horizontal: false),
                          options: Constraints.Pin.allCases.map { Self.name($0, horizontal: false) }) { choice in
                    guard let pin = Constraints.Pin.allCases.first(where: { Self.name($0, horizontal: false) == choice }) else { return }
                    editor.updateSelection("Change Constraints") { $0.constraints.vertical = pin }
                }
            }
        }
    }

    private func title(_ axis: KeyPath<Constraints, Constraints.Pin>, horizontal: Bool) -> String {
        let pins = Set(layers.map { $0.constraints[keyPath: axis] })
        return pins.count == 1 ? Self.name(pins.first!, horizontal: horizontal) : "Mixed"
    }

    private static func name(_ pin: Constraints.Pin, horizontal: Bool) -> String {
        switch pin {
        case .start: horizontal ? "Left" : "Top"
        case .end: horizontal ? "Right" : "Bottom"
        case .both: horizontal ? "Left & Right" : "Top & Bottom"
        case .center: "Center"
        case .scale: "Scale"
        }
    }
}

extension Layer {
    /// Groups with a stack show as stacks (a row or a column).
    var typeTitle: String {
        kind == .group && stack != nil ? "Stack" : kind.title
    }

    var symbolName: String {
        guard kind == .group, let stack else { return kind.symbolName }
        return stack.direction == .horizontal ? "rectangle.split.3x1" : "rectangle.split.1x2"
    }
}

/// Align buttons (to each other, or a single layer to its artboard), distribute buttons and the
/// spacing between the selected layers, which can be typed to space them exactly.
struct AlignSection: View {
    let editor: DocumentEditor
    let layers: [Layer]
    let perform: (CommandID) -> Void

    private static let buttons: [(CommandID, String, String)] = [
        (.alignLeft, "align.horizontal.left", "Align left (⌥A)"),
        (.alignHorizontalCenter, "align.horizontal.center", "Align horizontal centers (⌥H)"),
        (.alignRight, "align.horizontal.right", "Align right (⌥D)"),
        (.alignTop, "align.vertical.top", "Align top (⌥W)"),
        (.alignVerticalCenter, "align.vertical.center", "Align vertical centers (⌥V)"),
        (.alignBottom, "align.vertical.bottom", "Align bottom (⌥S)"),
        (.distributeHorizontally, "distribute.horizontal", "Distribute horizontally (⌃⌥H)"),
        (.distributeVertically, "distribute.vertical", "Distribute vertically (⌃⌥V)"),
    ]

    var body: some View {
        let _ = editor.revision
        let ids = layers.map(\.id)
        InspectorSection {
            HStack(spacing: 2) {
                ForEach(Self.buttons, id: \.0) { command, symbol, help in
                    if command == .distributeHorizontally { Spacer(minLength: 4) }
                    IconButton(symbol: symbol, help: help) { perform(command) }
                        .disabled(command.alignEdge == nil && layers.count < 3)
                        .opacity(command.alignEdge == nil && layers.count < 3 ? 0.35 : 1)
                }
            }
            if layers.count >= 2 {
                HStack(spacing: 8) {
                    NumberField(.symbol("arrow.left.and.right"), help: "Horizontal spacing: type a gap to space the layers exactly",
                                value: editor.document.uniformSpacing(of: ids, horizontally: true), placeholder: "—") { gap in
                        editor.distribute(horizontally: true, spacing: gap)
                    }
                    NumberField(.symbol("arrow.up.and.down"), help: "Vertical spacing: type a gap to space the layers exactly",
                                value: editor.document.uniformSpacing(of: ids, horizontally: false), placeholder: "—") { gap in
                        editor.distribute(horizontally: false, spacing: gap)
                    }
                }
            }
        }
    }
}
