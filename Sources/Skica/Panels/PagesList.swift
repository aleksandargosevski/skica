import SkicaCore
import SwiftUI

/// The page list above the layers: click to show a page, double-click to rename, + to add.
struct PagesList: View {
    let editor: DocumentEditor

    @State private var renaming: PageID?
    @State private var name = ""

    private static let rowHeight: CGFloat = 26
    private static let maxHeight: CGFloat = 160

    var body: some View {
        let _ = editor.revision
        let pages = editor.document.pages
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Pages")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                IconButton(symbol: "plus", help: "New page") { editor.addPage() }
            }
            .padding(.leading, 14)
            .padding(.trailing, 8)
            .frame(height: 32)
            ScrollView {
                VStack(spacing: 1) {
                    ForEach(pages) { page in row(page) }
                }
                .padding(.horizontal, 6)
            }
            .frame(height: min(CGFloat(pages.count) * (Self.rowHeight + 1), Self.maxHeight))
            Divider().padding(.top, 6)
        }
    }

    private func row(_ page: Page) -> some View {
        let isCurrent = page.id == editor.pageID
        return HStack(spacing: 8) {
            Image(systemName: "doc")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            if renaming == page.id {
                KeyTextField(text: $name, font: .systemFont(ofSize: 12), isBordered: false, focusOnAppear: true,
                             onSubmit: { finishRenaming(page) }, onEndEditing: { finishRenaming(page) })
            } else {
                Text(page.name)
                    .font(.system(size: 12, weight: isCurrent ? .semibold : .regular))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(height: Self.rowHeight)
        .background(isCurrent ? AnyShapeStyle(.tint.opacity(0.14)) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { startRenaming(page) }
        .simultaneousGesture(TapGesture().onEnded { editor.showPage(page.id) })
        .contextMenu {
            Button("Rename") { startRenaming(page) }
            Button("Delete") {
                editor.showPage(page.id)
                editor.removeCurrentPage()
            }
            .disabled(editor.document.pages.count < 2)
        }
    }

    private func startRenaming(_ page: Page) {
        name = page.name
        renaming = page.id
    }

    private func finishRenaming(_ page: Page) {
        guard renaming == page.id else { return }
        renaming = nil
        editor.renamePage(page.id, to: name)
    }
}
