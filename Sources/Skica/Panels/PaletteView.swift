import SkicaCore
import SwiftUI

struct PaletteItem: Identifiable {
    let id: String
    let title: String
    var subtitle: String?
    var symbol: String
    var shortcut: String?
    let run: () -> Void
}

/// Raycast-style search over commands and layers. ↑/↓ move, ↩ runs, esc closes.
struct PaletteView: View {
    let placeholder: String
    let items: [PaletteItem]
    /// More items for a non-empty query, e.g. matching layers.
    let search: (String) -> [PaletteItem]
    let close: () -> Void

    @State private var query = ""
    @State private var selected = 0

    private static let resultLimit = 60

    var body: some View {
        let results = self.results
        VStack(spacing: 0) {
            KeyTextField(
                text: $query,
                placeholder: placeholder,
                font: .systemFont(ofSize: 16),
                isBordered: false,
                focusOnAppear: true,
                onSubmit: { run(results) },
                onStep: { direction, _ in
                    move(by: -direction, count: results.count)
                    return true
                }
            )
            .frame(height: 30)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            Divider()
            if results.isEmpty {
                Text("No matches")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(results.enumerated()), id: \.element.id) { index, item in
                                PaletteRow(item: item, isSelected: index == selected)
                                    .id(index)
                                    .contentShape(Rectangle())
                                    .onTapGesture { item.run(); close() }
                            }
                        }
                        .padding(6)
                    }
                    .frame(maxHeight: 380)
                    .onChange(of: selected) { proxy.scrollTo(selected) }
                }
            }
        }
        .frame(width: 580)
        .fixedSize(horizontal: false, vertical: true)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator))
        .shadow(color: .black.opacity(0.25), radius: 24, y: 10)
        .onChange(of: query) { selected = 0 }
    }

    private var results: [PaletteItem] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return items }
        return (items + search(trimmed))
            .compactMap { item in FuzzyMatch.score(trimmed, in: item.title).map { (item, $0) } }
            .sorted { $0.1 > $1.1 }
            .prefix(Self.resultLimit)
            .map(\.0)
    }

    private func move(by offset: Int, count: Int) {
        guard count > 0 else { return }
        selected = (selected + offset + count) % count
    }

    private func run(_ results: [PaletteItem]) {
        guard results.indices.contains(selected) else { return }
        let item = results[selected]
        close()
        item.run()
    }
}

private struct PaletteRow: View {
    let item: PaletteItem
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: item.symbol)
                .frame(width: 18)
                .foregroundStyle(isSelected ? .white : .secondary)
            Text(item.title)
                .lineLimit(1)
            if let subtitle = item.subtitle {
                Text(subtitle)
                    .lineLimit(1)
                    .foregroundStyle(isSelected ? .white.opacity(0.75) : .secondary)
            }
            Spacer()
            if let shortcut = item.shortcut {
                Text(shortcut)
                    .font(.system(size: 11, design: .rounded))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
            }
        }
        .font(.system(size: 13))
        .foregroundStyle(isSelected ? .white : .primary)
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 6))
    }
}

/// Every shortcut, grouped like the menus. `?` or esc closes it.
struct ShortcutsView: View {
    let keymap: Keymap

    private static let canvasKeys: [(String, String)] = [
        ("Move selection", "← → ↑ ↓  (⇧ ×10)"),
        ("Resize from right/bottom", "⌘ + arrows  (⇧ ×10)"),
        ("Resize from left/top", "⌘⌥ + arrows"),
        ("Pan", "space + drag / arrows, or arrows with nothing selected"),
        ("Zoom", "⌘ + scroll, pinch"),
        ("Square / 45° / from center", "⇧ / ⇧ / ⌥ while dragging"),
        ("Don't snap", "⌃ while dragging"),
        ("Select deep", "⌘-click"),
        ("Into a group / edit text / edit points", "double-click"),
        ("Pen: curve / close / finish", "drag / click first point / ↩"),
        ("Pen: straight after a curve", "click the last point again"),
        ("Pen: sharp turn between curves", "⌥-drag, or drag from the last point"),
        ("Points: next / type / delete", "⇥ / 1–4 / ⌫"),
        ("Add to selection", "⇧-click, marquee"),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Keyboard Shortcuts").font(.title3.weight(.semibold))
                LazyVGrid(columns: [GridItem(.flexible(), alignment: .top), GridItem(.flexible(), alignment: .top)], alignment: .leading, spacing: 18) {
                    ForEach(CommandCategory.allCases, id: \.self) { category in
                        section(category.rawValue, rows: CommandID.allCases.filter { $0.category == category }.map { command in
                            (command.title, keymap.sequences(for: command).map(\.displayText).joined(separator: "  or  "))
                        })
                    }
                    section("Canvas", rows: Self.canvasKeys)
                }
                Text("Change shortcuts in ~/.config/skica/keybindings.json")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(24)
        }
        .frame(width: 760, height: 560)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator))
        .shadow(color: .black.opacity(0.25), radius: 24, y: 10)
    }

    private func section(_ title: String, rows: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(rows, id: \.0) { row in
                HStack(alignment: .firstTextBaseline) {
                    Text(row.0)
                    Spacer(minLength: 12)
                    Text(row.1.isEmpty ? "—" : row.1)
                        .font(.system(size: 12, design: .rounded))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                }
                .font(.system(size: 12))
            }
        }
    }
}

extension KeySequence {
    var displayText: String {
        chords.map { $0.symbols.joined() }.joined(separator: " ")
    }
}
